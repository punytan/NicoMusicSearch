#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Encode;
use lib '/site_perl';
use Unicode::Normalize qw/NFKC/;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::HTTP;
use AnyEvent::Handle;
use AnyEvent::Twitter;
use AnyEvent::Twitter::EnableOAuth;
use AnyEvent::DBI;
use Web::Scraper;
use XML::Simple;
use Data::Dumper;

my $dbh;

my @word_list = ( # regexp
   "ギター", "弾き語り", "ピアノ", "弾き語る", "アコギ",
);

my @normalized_word_list = map {
    my $word =$_;
    $word = uc NFKC $word;
    $word =~ tr/ぁ-ん/ァ-ン/;
    $word;
} @word_list;

my $config = XMLin('/home/puny/.account/twitter/NicoMusicSearch.xml') or die $!;

my $twitty = AnyEvent::Twitter->new(
    consumer_key        => $config->{consumer_key},
    consumer_secret     => $config->{consumer_secret},
    access_token        => $config->{access_token},
    access_token_secret => $config->{access_token_secret},
);

my $server = get_alertinfo();

sub tweeted_cb {
    my ($twitty, $status, $js_status, $error) = @_;
    (defined $error)
        ? print encode_utf8 "Tweet Error: $error\n"
        : print encode_utf8 "Tweet Success: $twitty\n"
    ;
}

sub make_sentence
{
    my ($html, $body_xml, $matched_word) = @_;
    my $sentence;
    my $scraper = scraper { process 'span#pedia a', 'user' => 'TEXT'; };
    my $part_num = $1 if ($html =~ m!参加人数：(\d+)<br>!gms);
    my $name = $scraper->scrape($html);

    my $title      = substr($body_xml->{streaminfo}->{title}, 0, 30);
    my $co_name    = substr($body_xml->{communityinfo}->{name}, 0, 30);

    return ($sentence, $part_num) unless (defined $part_num);

    $sentence  = "【word】$matched_word\n";
    $sentence .= "【community】$co_name (コミュ人数 $part_num 人)\n";
    $sentence .= "【title】$title\n";
    $sentence .= "【user】$name->{user}\n";
    $sentence .= "http://nico.ms/$body_xml->{request_id} #nicolive";
    return ($sentence, $part_num);
}

sub matched_cb {
    my ($body, $hdr, $body_xml, $matched_word, $user_id) = @_;

    return if (!defined $body);

    $dbh->exec("insert into history(user_id) values(?)", $user_id, sub {
            my ($dbh, $rows, $rv) = @_;

            $#_ or return "failure : $@";

            my ($sentence, $part_num) = make_sentence(decode_utf8($body), $body_xml, $matched_word);

            return unless (defined $part_num);

            $twitty->update_status($sentence, sub { tweeted_cb(); }) if ($part_num > 400);
        }
    );
}

sub http_request_cb { 
    my ($body, $hdr, $user_id, $lv_num) =@_;
    
    return if (!defined $body);
    
    my $formed_body = decode_utf8 $body;
    $formed_body = uc NFKC $formed_body;
    $formed_body =~ tr/ぁ-ん/ァ-ン/;

    my @matched_words = grep {
        my $word = $_;
        $word if ($formed_body =~ /$word/);
    } @normalized_word_list;
    
    return if (!defined $matched_words[0] );

    my $body_xml = XMLin(decode_utf8 $body);
    http_request (
        GET     => "http://live.nicovideo.jp/watch/lv$lv_num",
        timeout => 10,
        on_body => sub { matched_cb(@_, $body_xml, $matched_words[0], $user_id); }
    );
}

sub socket_read_cb {
    my ($handle, $chat_tag) = @_;

    my $decoded_chat_tag = decode_utf8 $chat_tag;
    
    if ($decoded_chat_tag =~ />(.*)</) {
        my ($lv_num, $co_num, $user_id) = split/,/, $1;
        if (defined $lv_num && defined $co_num && defined $user_id) {
            http_request(
                GET     => "http://live.nicovideo.jp/api/getstreaminfo/lv$lv_num",
                timeout => 3,
                on_body => sub { http_request_cb(@_, $user_id, $lv_num); }
            );
        }
    }
    $handle->push_read(line => "\0", sub { socket_read_cb(@_); });
}

sub connection_cb {
    my ($fh) = @_ or die $!;
    my $thread_tag_attr = {
        thread   => $server->{thread},
        res_from => '-1',
        version  => '20061206',
    };

    my $thread_tag = XMLout($thread_tag_attr, RootName => 'thread') . "\0";

    my $handle; $handle = new AnyEvent::Handle(
        fh       => $fh,
        on_error => sub {
            warn "Error $_[2]\n";
            $_[0]->destroy;
        },
        on_eof   => sub {
            $handle->destroy;
            warn "Done\n";
        }
    );       
    $handle->push_write($thread_tag);
    $handle->push_read(line => "\0", sub { socket_read_cb(@_); });
}

my $cv = AE::cv;
$dbh = new AnyEvent::DBI "DBI:SQLite:dbname=history.db", "", "",
    PrintError => 0,
    on_error   => sub {
        return;
    };

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

if ($hour == 6) {
    my $cv1 = AE::cv;
    $dbh->exec("drop table if exists history;", , sub{
            my ($dbh, $rows, $rv) = @_;
            $#_ or die "failure : $@";
            $cv1->send;
        }
    );
    $cv1->recv;
}

my $cv2 = AE::cv;
$dbh->exec("create table if not exists history(user_id unique);", , sub {
        $cv2->send;
    }
);
$cv2->recv;

my $connection = tcp_connect(
    $server->{addr},
    $server->{port},
    sub { connection_cb(@_); }
);

my $bot_kill_w = AnyEvent->timer(
    after => 10801,
    cb    => sub { exit; },
);

$cv->recv;

sub get_alertinfo
{
    use LWP::UserAgent;
    my $url = 'http://live.nicovideo.jp/api/getalertinfo';
    my $ua  = LWP::UserAgent->new();
    my $res = $ua->get($url);
    die "$res->status_line" unless ($res->is_success);
    my $xml = XMLin($res->decoded_content);
    die "Fatal: Server status $xml->{status}" if ($xml->{status} ne 'ok');
    return $xml->{ms};
}
