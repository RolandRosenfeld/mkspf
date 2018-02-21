#!/usr/bin/perl

# script to expand/flatten SPF records
# Fri Feb 23 15:27:06 EST 2018 jason@oasys.net

# Provide path to the zone file (assumed to be same as domain name) as only
# argument on the commandline.  Script will search for a 'mkspf' TXT record
# and output a file for inclusion in the main zone.

use strict;
use warnings;
use Net::DNS;
use Net::CIDR::Lite;
use File::Basename;

my $DEBUG  = 0;
my $net4   = new Net::CIDR::Lite;
my $net6   = new Net::CIDR::Lite;
my $dns    = new Net::DNS::Resolver;

my $MAXQ   = 10;  # RFC7208 query limit
my $MAXS   = 255; # bind TXT RR string size limit
my $MAXP   = 512; # UDP payload limit
my $MAXH   = 32;  # overhead estimate for non-answer data in DNS response

my ($initial_domain, $path) = fileparse(shift);
my $domain = $initial_domain;
my @spf    = ();
my @end    = ();

process_spf($domain, read_file($domain));

my $start  = 'v=spf1';
my $end    = join(' ', @end);
my $maxp   = $MAXP - $MAXH - length("_N._spf.$domain") - length("$start " . " $end");

# build lists of netblocks to be included
my $i = 1; @{$spf[$i]} = ();
for ($net4->list(), $net6->list()) {
  my $proto = /:/ ? 6 : 4;
  my $add   = "ip${proto}:$_";
  @{$spf[++$i]} = () if length(join(' ', @{$spf[$i]}, $add)) > $maxp;
  push @{$spf[$i]}, $add;
}

# check against RFC2208 query limit, accounting for first redirect lookup
$DEBUG && print "DNS query count: ", (scalar @spf + 1), "/$MAXQ\n";
die "DNS query limit ($MAXQ) reached, exiting.\n" if (scalar @spf + 1) > $MAXQ;

# build TXT records
for (1 .. $#spf) {
  push @{$spf[0]}, "include:_$_._spf.${domain}";
  $spf[$_] = format_rr("_$_._spf", 'TXT', @{$spf[$_]});
}
$spf[0] = format_rr('_spf', 'TXT', @{$spf[0]});

write_file($domain);

sub get_spf {
  my $domain = shift;
  $DEBUG && print "get_spf() $domain\n";
  my $query = $dns->search( $domain, 'TXT' ) or warn "no TXT record for $domain\n";
  foreach my $rr ( $query->answer ) {
    next unless $rr->type eq 'TXT' and $rr->txtdata =~ /^v=spf1/;
    process_spf($domain, $rr->txtdata);
  }
}

sub process_spf {
  my $domain = shift;
  for my $term (split(/\s+/, shift)) {
    parse_directive($term, $domain);
  }
}

sub read_file {
  my $domain = shift;
  my @out;
  open (F, "<$path/$domain") or die "cannot read file \"$path/$domain\": $!\n";

  while(<F>) {
    next unless my $n = /^mkspf\s+.*\s+TXT\s+/.../\)/;  # multiline mkspf TXT RR
    next unless /\"\s*([^"]+)\s*\"/;                    # content between ""
    push(@out, split(/\s+/, $1));
  }
  die "no mkspf TXT record found" unless scalar @out;
  return join(' ', @out);
}

sub write_file {
  my $domain = shift;
  open(SPF, ">$path/_spf.${domain}") or die "cannot write file $path/_spf.${domain}: $!\n";
  print SPF qq(;
; This file is automatically generated by mkspf.  Do not modify directly.
; To update, make changes to the mkspf TXT RR in main ${domain} zone file.
;
);
  for (@spf) { print SPF; }
}

sub parse_directive {
  $_ = shift;
  my $domain = shift;
  $DEBUG && print "parse_directive() $_ $domain\n";
  return if /^v=spf1/;
  my ($modifier, $term, $value) =
     /^([-?+~])?(all|include|a|mx|ptr|ip4|ip6|exists|redirect)(?::(\S+))?$/;
  if      ($term eq 'include')  { get_spf($value);
  } elsif ($term eq 'redirect') { get_spf($value);
  } elsif ($term eq 'a')        { add_ip(get_rr('A', $value));
  } elsif ($term eq 'mx')       { add_ip(get_rr('MX', $domain));
  } elsif ($term eq 'exists')   { warn "ignoring EXISTS:$value\n";
  } elsif ($term eq 'all')      { push @end, "${modifier}all" if $domain eq $initial_domain;
  } elsif ($term eq 'ptr')      { warn "ignoring PTR per RFC7208\n";
  } elsif ($term eq 'ip4')      { add_ip($value);
  } elsif ($term eq 'ip6')      { add_ip($value);
  } else {
    warn "unknown directive: \"$_\"\n";
  }
}

sub add_ip {
  for my $ip (@_) {
    $DEBUG && print "add_ip() $ip\n";
    if ($ip =~ /:/) {
      $net6->add_any($ip);
    } else {
      $net4->add_any($ip);
    }
  }
}

sub get_rr {
  my $type = uc(shift);
  my $name = shift;
  $DEBUG && print "get_rr() $type $name\n";
  my @rr;
  my $query = $dns->search( $name, $type );
  if ($query) {
    foreach my $rr ( $query->answer ) {
      next unless $rr->type eq $type;
      if ($type eq 'A') {
        push(@rr, $rr->address);
      } elsif ($type eq 'MX') {
        push(@rr, get_rr('A', $rr->exchange));
      } else {
        warn "unknown type \'$type\' DNS lookup for $name\n";
      }
    }
  } else {
    warn "no $type record for $name\n";
  }
  return @rr;
}

sub format_rr {
  my $label = shift;
  my $type  = shift;
  my $space = 16;
  my @r=(); my $i=0; $r[0]='';
  for ($start, @_, $end) {
    # split each RR into multiple RFC4408-style strings
    $r[++$i]='' if length("$r[$i] $_") > $MAXS;
    if ($_ eq $start) {
      $r[$i] = $_;
    } else {
      $r[$i] .= " $_";
    }
  }
  return "$label" . ' ' x ($space - length($label)) . "IN      $type " .
         join(' ', map { qq{"$_"} } @r) .
         "\n";
}
