#!/usr/bin/perl

use Data::Dumper;
use Date::Parse;
use POSIX qw{ strftime };
use BerkeleyDB;
use MLDBM qw(BerkeleyDB::Hash);
use File::Spec::Functions qw{ catfile };
use DateTime;
use DateTime::Format::Mail;
require LWP::UserAgent;
require XML::RSS;
require HTML::TokeParser;

use strict;
use warnings;

sub callback;

my $UA       = 'Mozilla/5.0 (Windows NT 6.1; rv:2.0) Gecko/20100921 Firefox/4.0';
my $RSSURL   = 'http://feeds.feedburner.com/foksuk/gLTI?format=xml';
my $DBFILE   = 'foksuk.db';
my $RSSFILE  = 'foksuk.rss';
my $IMGDIR   = 'cartoons/';
my $NUMITEMS = 10;


#main
{
	get_and_parse_feed();
	exit 0;
}
die;

sub get_url
{
	my $url     = shift or die;
	my $referer = shift || undef;

	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);
	$ua->env_proxy;
	$ua->agent($UA);
	$ua->default_header( 'Referer' => $referer ) if $referer;

	my $response = $ua->get($url);
	if ($response->is_success) {
		return $response->decoded_content;
	}
	else {
		die("get_url failed for `$url': ".$response->status_line."\n");
	}
}

sub parse_feed
{
	my $xml = shift or die;
	my $feed = XML::RSS->new;
	$feed->parse($xml);

	my @items;

	foreach my $item ( @{$feed->{'items'}} )
	{
		my $fulltitle = $item->{'title'}   || '';
		my $link      = $item->{'link'}    || '';
		my $time      = $item->{'pubDate'} || '';

		my $unixtime = str2time($time);
		my $date     = strftime('%Y-%m-%d',localtime($unixtime));

		my ($title,$src) = $fulltitle =~ m{^(.*?)\s+\((.*?)\)};

		push @items, {
			'title'    => $title,
			'source  ' => $src,
			'link'     => $link,
			'date'     => $date,
		};
	}

	#print Dumper \@items;

	return @items;
}

sub parse_page_get_link
{
	my $html = shift or die;

	my $p = HTML::TokeParser->new(\$html);

	# find base href (or start of body)
	my $base_href = '';
	my $base = $p->get_tag('base','/head');
	if ($base->[0] eq 'base')
	{
		if (exists $base->[1]->{'href'})
		{
			$base_href = $base->[1]->{'href'};
		}
	}
	

	# find image
	while( my $tag = $p->get_tag('div') )
	{
		next unless     exists $tag->[1]->{'class'} 
		            and $tag->[1]->{'class'} eq 'cartoon';
		my $img = $p->get_tag('img');
		return $base_href . $img->[1]->{'src'};
	}
	return;
}

sub get_cartoon
{
	my $item = shift or die;

	my $html     = get_url( $item->{'link'} );
	my $img_link = parse_page_get_link( $html );
	my $img      = get_url( $img_link,  $item->{'link'} );

	print "Found `$img_link'\n";

	$item->{'link'} =~ m{cid=(\d+)};
	my $fname = sprintf('%s_%i.gif', $item->{'date'}, $1||0);

	print "Saving to $fname\n";

	open( my $fd, '>:bytes', catfile($IMGDIR,$fname) ) or die("Can't open file $IMGDIR/$fname: $!\n");
	print $fd $img;
	close($fd);

	return ($fname,$img_link);
}

sub todate
{
	my $thetime = shift or die;

	my ($y,$m,$d) = $thetime =~ m/^(\d{4})-(\d{2})-(\d{2})/;

	my $dt = DateTime->new(
		year      => $y,
		month     => $m,
		day       => $d,
		hour      => 0,
		minute    => 0,
		second    => 0,
		time_zone => 'Europe/Amsterdam',
	);

	return $dt;
}

sub write_rss
{
	my $rssfile = shift or die;
	my $items   = shift or die;

	# sort with most recent first
	my @keys = sort {
		$items->{$b}->{'date'} cmp $items->{$a}->{'date'}
	} keys %$items;

	my $now    = DateTime->now;
	my $latest = todate( $items->{ $keys[0] }->{'date'} );

	my $rss = XML::RSS->new(
		'version'  => '2.0',
		'encoding' => 'UTF-8',
	);
	$rss->channel(
		title          => 'Fokke & Sukke Daily Cartoon',
		link           => 'http://foksuk.nl',
		language       => 'nl',
		description    => 'De dagelijkse Fokke&Sukke, rechtstreeks van de website',
		pubDate        => DateTime::Format::Mail->format_datetime( $latest ),
		lastBuildDate  => DateTime::Format::Mail->format_datetime( $now ),
		skipDays       => [ 'Sunday' ],
		ttl            => 24*60,
		syn => {
			updatePeriod     => "daily",
			updateFrequency  => "1",
			updateBase       => "1901-01-01T00:00+00:00",
		},
	);


	foreach my $k (@keys[0..$NUMITEMS-1])
	{
		print "=>$k\n";
		my $item = $items->{$k};

		my $desc = '<img src="' . $item->{'img_remote'} . '">';
		my $date = DateTime::Format::Mail->format_datetime(
			todate( $item->{'date'} )
		);

		$rss->add_item(
			'title'        => $item->{'title'},
			'permaLink'    => $item->{'img_remote'},
			'description'  => $desc,
			'pubDate'      => $date,
			'dc' => { date => $date },
		);
	}

	# write to disk
	open(my $fd, '>:utf8', $rssfile) or die("Can't open `$rssfile': $!\n");
	print $fd $rss->as_string();
	close($fd);
}

sub get_and_parse_feed
{
	my $xml = get_url($RSSURL);
	my @items = parse_feed($xml);

	tie( my %db, 'MLDBM',
		-Filename => $DBFILE,
		-Flags    => DB_CREATE | DB_INIT_LOCK
	) or die "Cannot open file $DBFILE: $! $BerkeleyDB::Error\n" ;

	foreach my $item (@items)
	{
		next if exists  $db{ $item->{'link'} };

		my ($localname,$remotename) = get_cartoon($item);
		$item->{'img_local'}  = $localname;
		$item->{'img_remote'} = $remotename;

		$db{ $item->{'link'} } = $item;

		printf("Added `%s' (%s)\n", $item->{'title'}, $item->{'date'});
	}

	write_rss($RSSFILE,\%db);

	untie %db;
}
