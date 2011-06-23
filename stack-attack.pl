#!/usr/bin/env perl
use 5.10.0;
use strict;
use warnings;
use HTTP::Async;
use HTTP::Request;
use App::Rad;
use LWP;
use JSON qw(to_json from_json);

sub setup {
    my $c = shift;
    $c->register_commands({
        create_servers => 'create x number of servers',
        delete_servers => 'delete all servers',
        servers        => 'run x number of server list requests',
        bad            => 'run x number of bad/invalid requests',
        images         => 'run x number of image list requests',
    });

    my $base_url = $ENV{NOVA_URL};
    die "NOVA_URL env var is missing. Did you forget to source novarc?\n"
        unless $base_url;
    $base_url =~ s(/$)();       # Remove trailing slash
    $base_url =~ s/v1\.0/v1.1/; # Switch to version 1.1
    $c->stash->{base_url} = $base_url;

    # Get the Auth Token
    my $ua = LWP::UserAgent->new();
    my $res = $ua->get(
        $base_url,
        'x-auth-key'  => $ENV{NOVA_API_KEY},
        'x-auth-user' => $ENV{NOVA_USERNAME},
    );  

    # Store auth_headers
    $c->stash->{auth_headers} = [
        "x-auth-token" => $res->header('x-auth-token'),
        "content-type" => "application/json"
    ];

    # Create body json
    $c->stash->{create_body_json} = to_json({
        server => {
            name      => 'test-server',
            imageRef  => '3',
            flavorRef => '1',
        }
    });
}

sub pre_process {
    my $c = shift;
    my ($num_runs) = @ARGV;

    die "The delete_servers command does not accept an arguments\n"
        if $c->cmd eq 'delete_servers' and $num_runs;

    $c->stash->{num_runs} = $num_runs || 1;
}

sub post_process {
    my $c = shift;
    my $output = $c->output;
    if (ref $output eq 'ARRAY') {
        say "Successes: $output->[0] Failures: $output->[1]";
    } else {
        say $output;
    }
}

App::Rad->run();

#---------- Commands ----------------------------------------------------------


sub create_servers {
    my $c = shift;
    my $base_url = $c->stash->{base_url};

    say "Creating " . $c->stash->{num_runs} . " servers...";
    return make_requests(
        $c->stash->{num_runs},
        "POST", 
        "$base_url/servers", 
        $c->stash->{auth_headers}, 
        $c->stash->{create_body_json}
    );
}

sub delete_servers {
    my $c = shift;
    my $base_url = $c->stash->{base_url};
    my ($successes, $failures, @errmsgs) = (0, 0);

    my $async = HTTP::Async->new;
    my $ua = LWP::UserAgent->new();

    my $res = $ua->get(
        "$base_url/servers", 
        'x-auth-token' => $c->stash->{auth_headers}->[1]
    );
    die "Error getting server list " . $res->content unless $res->status_line =~ /^2/;

    my $data = from_json($res->content);
    my @servers = @{ $data->{servers} };

    say "Deleting " . @servers . " servers...";
    foreach my $server (@servers){
        my $id = $server->{id};
        
        my $reval = make_requests(
            1,
            "DELETE", 
            "$base_url/servers/$id", 
            $c->stash->{auth_headers}, 
        );
        $successes += $reval->[0];
        $failures += $reval->[1];
    }
    return [$successes, $failures];
}

sub bad {
    my $c = shift;
    my $base_url = $c->stash->{base_url};

    say "Sending " . $c->stash->{num_runs} . " invalid requests...";

    return make_requests(
        $c->stash->{num_runs},
        "GET", 
        "$base_url/invalid-resource", 
        $c->stash->{auth_headers},
    );
}

sub images {
    my $c = shift;
    my $base_url = $c->stash->{base_url};

    return make_requests(
        $c->stash->{num_runs},
        "GET", 
        "$base_url/images", 
        $c->stash->{auth_headers},
    );
}

sub servers {
    my $c = shift;
    my $base_url = $c->stash->{base_url};

    say "Sending " . $c->stash->{num_runs} . " /servers requests...";
    return make_requests(
        $c->stash->{num_runs},
        "GET", 
        "$base_url/servers", 
        $c->stash->{auth_headers},
    );
}

#---------- Helpers -----------------------------------------------------------

sub make_requests {
    my ($num_reqs, $method, $url, $headers, $body) = @_;
    my ($successes, $failures, @errmsgs) = (0, 0);
    my $async = HTTP::Async->new;

    for my $i (1 .. $num_reqs) {
        my $req = HTTP::Request->new($method => $url, $headers, $body);
        $async->add($req);
    }
    while (my $res = $async->wait_for_next_response) {
        if ($res->status_line =~ /^2/){
            $successes++;
        } else {
            $failures++;
            push @errmsgs, $res->content;
        }
    }
    return [$successes, $failures];
}
