#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.012;

use Encode;
use Data::Dumper;

use AnyEvent;
use AnyEvent::DBI;
use AnyEvent::HTTP;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Twitter;

use XML::Simple;
use Web::Scraper;
use Unicode::Normalize qw/NFKC/;

our $server = {};
our @TWEETED;

my @words = (
   "ギター", "弾き語り", "ピアノ", "弾き語る", "アコギ",
); # Regexp.

my @normalized_words;
for (@words) {
    my $word = uc NFKC $_;
    $word =~ tr/ぁ-ん/ァ-ン/;
    push @normalized_words, $word;
}

my $config = XMLin("$ENV{HOME}/.account/twitter/NicoMusicSearch.xml");
my $twitty = AnyEvent::Twitter->new(%$config);

my $get_alertinfo_cv = AE::cv;
http_get 'http://live.nicovideo.jp/api/getalertinfo', sub {
    my $alertinfo =  XMLin(shift);

    exit if ($alertinfo->{status} ne 'ok'); 
    
    $server = $alertinfo->{ms};
    $get_alertinfo_cv->send;
}; 
$get_alertinfo_cv->recv;


my $conn_cv = AE::cv;

print Dumper [$config, $server];
my $conn = tcp_connect($server->{addr}, $server->{port}, sub {
    my $fh = shift or exit;

    my $handle; $handle = AnyEvent::Handle->new(
        fh       => $fh,
        on_error => sub {
            warn "error $_[2]\n";
            $_[0]->destroy;
        },
        on_eof   => sub {
            $handle->destroy;
            warn "Done\n";
        },
    );

    my $tag_attr = {
        thread   => $server->{thread},
        res_form => '-1',
        version  => '20061206',
    };

    $handle->push_write(XMLout($tag_attr, RootName => 'thread') . "\0");
    $handle->push_read(line => "\0", \&reader);
});

my $reset_timer;

$conn_cv->recv;

exit;

sub reader {
    my $handle = shift or exit;
    my $line = shift;

    if ($line =~ />([^,]+),([^,]+),([^,]+)</) {
        my %stream = (lv => $1, co => $2, user => $3);

        http_get "http://live.nicovideo.jp/api/getstreaminfo/lv" . $stream{lv}, sub {
            my $xml_body = shift or return;

            if (my $word = is_matched($xml_body, $stream{user})) {
                http_get "http://live.nicovideo.jp/watch/lv" . $stream{lv}, sub {
                    my $body = decode_utf8(shift) or return;

                    if (is_over400($body)) {
                        my $status = construct_status($body, XMLin($xml_body), $word, \%stream);
                        $twitty->request(api => 'statuses/update', method => 'POST', params => {
                            status => $status }, sub { say encode_utf8 $_[1]->{text}});
                    }
                };
            }
        };
    }

    $handle->push_read(line => "\0", \&reader);
}

sub is_matched {
    my ($body, $user) = @_;

    my $formed = uc NFKC decode_utf8 $body;
    $formed =~ tr/ぁ-ん/ァ-ン/;

    my @matched_words;
    for (my $i = 0; $i < scalar @normalized_words; $i++) {
        push @matched_words, $words[$i] if $formed =~ $normalized_words[$i];
    }

    return undef unless (scalar @matched_words);

    for (@TWEETED) {
        return undef if $user eq $_;
    }

    $matched_words[0] =~ s/\\//g;
    return $matched_words[0];
}

sub construct_status {
    my ($body, $xml, $word, $stream) = @_;

    my $scraper = scraper { process 'span#pedia a', 'name' => 'TEXT'; };
    my $user = $scraper->scrape($body);

    my $user_name = $user ? $user : '-';
    my $part  = $body =~ m!参加人数：<strong style="font-size:14px;">(\d+)</strong>!gms ? $1 : 0;
    my $title = substr $xml->{streaminfo}{title}, 0, 30;
    my $com   = substr $xml->{communityinfo}{name}, 0, 30;

    return "[$word] $com (${part}人) - $title / $user->{name} http://nico.ms/$xml->{request_id} #nicolive [$stream->{co}]";
}

sub is_over400 {
    my $body = shift;

    my $part = $body =~ m!参加人数：<strong style="font-size:14px;">(\d+)</strong>!gms ? $1 : 0;
    return $part > 400 ? $part : undef;
}

__END__

