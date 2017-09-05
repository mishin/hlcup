#!/usr/bin/env perl

use utf8;
use open qw(:utf8 :std);
use 5.016;
# use feature 'fc';
use JSON::XS;
use DDP;
use Time::HiRes qw(time);
use List::Util qw(max);
use Getopt::Long;
my $port;
my $debug;
BEGIN {
	$port = 80;
	GetOptions(
		'p|port=n' => \$port,
		'd|debug' => \$debug,
	) or die;
}
use constant DEBUG => $debug;

our $JSON = JSON::XS->new->utf8;

our %USERS;
our %COUNTRIES; our $COUNTRY_MAX=0; # by name
our %COUNTRY_ID;
our %LOCATIONS;

our %VISITS;

our @VISIT_FIELDS = qw(location user visited_at mark);

our %USER_VISITS;
our %LOCATION_VISITS;

sub get_country($) {
	my $key = shift;
	my $cnkey = fc($key);
	my $country = $COUNTRIES{ $cnkey } ||= do {
		my $id = ++$COUNTRY_MAX;
		$COUNTRY_ID{$id} = { id => $id, key => $cnkey, name => $key };
	};
	return $country->{id};
}

our $DST = '/tmp/unpacked';

if (DEBUG) {
	$DST = "hlcupdocs/data";
}
else {
	system("unzip -o /tmp/data/data.zip -d $DST/")
		== 0 or die "Failed to unpack: $?";
}

my $start = time; my $count = 0;
for my $f (<$DST/users_*.json>) {
	my $data = do { open my $fl, '<:raw', $f or die "$!"; local $/; $JSON->decode(<$fl>)->{users}};
	warn sprintf "Loading %d users from %s\n",0+@$data,$f;
	for my $u (@$data) {
		$USERS{$u->{id}} = $u;
		++$count;
	}
}
warn sprintf "Loaded %d users in %0.4fs\n", $count, time-$start;

my $start = time; my $count = 0;
for my $f (<$DST/locations_*.json>) {
	my $data = do { open my $fl, '<:raw', $f or die "$!"; local $/; $JSON->decode(<$fl>)->{locations}};
	warn sprintf "Loading %d locations from %s\n",0+@$data,$f;
	for my $l (@$data) {
		# p $l unless %COUNTRIES;
		my $cnkey = fc($l->{country});
		my $country = $COUNTRIES{ $cnkey } ||= do {
			my $id = ++$COUNTRY_MAX;
			$COUNTRY_ID{$id} =
			+{ id => $id, key => $cnkey, name => $l->{country} }
		};
		$l->{country} = get_country $l->{country};
		++$count;
		$LOCATIONS{$l->{id}} = $l;
	}
}
# p %COUNTRIES;
warn sprintf "Loaded %d locations in %0.4fs, found %d countries\n", $count, time-$start, 0+keys %COUNTRIES;

my $start = time; my $count = 0;
for my $f (<$DST/visits_*.json>) {
	my $data = do { open my $fl, '<:raw', $f or die "$!"; local $/; $JSON->decode(<$fl>)->{visits}};
	warn sprintf "Loading %d visits from %s\n",0+@$data,$f;
	for my $v (@$data) {
		my $loc = $LOCATIONS{$v->{location}};
		my $usr = $USERS{$v->{user}};
		$VISITS{$v->{id}} = $v;
		my $uvl = {
			user => $usr,
			visit => $v,
			location => $loc,
		};

		push @{ $USER_VISITS{ $v->{user} } },         $uvl;
		push @{ $LOCATION_VISITS{ $v->{location} } }, $uvl;

		++$count;
	}
}
warn sprintf "Loaded %d visits in %0.4fs\n", $count, time-$start;

my $start = time;
my $max = 0;
for my $visits (values %LOCATION_VISITS, values %USER_VISITS) {
	@$visits = sort {
		$a->{visit}{visited_at} <=> $b->{visit}{visited_at}
	} @$visits;
	$max = max($max,0+@$visits);
}
warn sprintf "Sorted %d visits in %0.4fs, max: %s\n", $count, time-$start, $max;

use lib glob("libs/*/lib"),glob("libs/*/blib/lib"),glob("libs/*/blib/arch");

use AnyEvent::HTTP::Server;
use EV;
use Time::Moment;

our %STAT;


sub dump_visits {
	my $name = shift;
	my $av = shift;
	say "$name ".(0+@$av);
	for (@$av) {
		printf "\t#%s\t@%s\t<%s>\t%20s#%s\t%4s -> %s:%s (%s)\n",
			$_->{visit}{id},
			Time::Moment->from_epoch($_->{visit}{visited_at}),
			$_->{user}{email},
			$_->{location}{place}, $_->{visit}{mark},
			$_->{location}{distance},
			$_->{location}{city},$_->{location}{country},$_->{location}{id}
	}
}

# dump_visits "TEST", $USER_VISITS{166};

my $srv = AnyEvent::HTTP::Server->new(
	host => 0,
	port => $port,
	DEBUG > 1 ? (
		on_reply => sub {
			say "\t$_[1]{Status} $_[1]{ResponseTime}";
			# p @_;
		},
	) : (),
	cb => sub {
		my $req = shift;
		my $path = $req->path;
		printf "%s %s\n", $req->method, $req->uri if DEBUG > 1;
		$STAT{$req->method}++;
		if ($req->method eq 'POST') {

			my $buf;
			return sub {
				unless (defined $buf) {
					$buf = $_[1];
				}
				else {
					$$buf .= ${$_[1]};
				}
				if ($_[0]) {
					my $data = eval { $JSON->decode( $$buf ) };
					$data and ref $data eq 'HASH'
						or return $req->reply(400, '{}');
						# or do { warn $$buf, $@; return $req->reply(400, '{}'); };

					# p $data;
					if ($path =~ m{^/users/(?:(\d+)|(new))$}) {
						# id: int32,
						# email: str[100], uniq
						# gender: f|m
						# first_name: str[50]
						# last_name: str[50]
						# birth_date: unix timestamp
						my $user;
						if ($1) {
							$user = $USERS{$1} or return $req->reply(404,'{}');
						}

						if (exists $data->{email}) {
							length $data->{email} and length $data->{email} < 100
								or return $req->reply(400,'{"error":"bad email"}');
						}
						if (exists $data->{birth_date}) {
							$data->{birth_date} =~ /^-?\d+$/
								or return $req->reply(400,'{"error":"bad birth_date"}');
						}
						if (exists $data->{gender}) {
							$data->{gender} =~ /^(f|m)$/
								or return $req->reply(400,'{"error":"bad gender"}');
						}
						if (exists $data->{first_name}) {
							length $data->{first_name} and length $data->{first_name} < 50
								or return $req->reply(400,'{"error":"bad first_name"}');
						}
						if (exists $data->{last_name}) {
							length $data->{last_name} and length $data->{last_name} < 50
								or return $req->reply(400,'{"error":"bad last_name"}');
						}

						if ($1) { # update
							for (qw(email birth_date gender first_name last_name)) {
								if (exists $data->{$_}) {
									$user->{$_} = $data->{$_};
								}
							}
						}
						else {
							$data->{id} =~ /^\d+$/
								or return $req->reply(400,'{"error":"bad id"}');

							$USERS{ $data->{id} }
								and return $req->reply(400,'{"error":"bad id"}');

							(exists( $data->{id})
							+ exists( $data->{email})
							+ exists( $data->{gender})
							+ exists( $data->{first_name})
							+ exists( $data->{last_name})
							+ exists( $data->{birth_date}))
							== 6 or return $req->reply(400,'{"error":"bad fields"}');

							$USERS{ $data->{id} } = $data;
						}
						return $req->reply(200,'{}');
					}
					elsif($path =~ m{^/locations/(?:(\d+)|(new))$}) {
						my $loc;
						if ($1) {
							$loc = $LOCATIONS{$1} or return $req->reply(404,'{}');
						}
						# id: int32,
						# place: text,
						# country: str[50],
						# city: str[50],
						# distance: int32,
						if (exists $data->{place}) {
							length $data->{place}
								or return $req->reply(400,'{"error":"bad place"}');
						}
						if (exists $data->{country}) {
							length $data->{country} and length $data->{country} < 50
								or return $req->reply(400,'{"error":"bad country"}');
						}
						if (exists $data->{city}) {
							length $data->{city} and length $data->{city} < 50
								or return $req->reply(400,'{"error":"bad city"}');
						}
						if (exists $data->{distance}) {
							$data->{distance} =~ /^\d+$/
								or return $req->reply(400,'{"error":"bad distance"}');
							$data->{distance} = $data->{distance};
						}

						if ($1) { # update
							$loc->{place} = $data->{place} if exists $data->{place};
							$loc->{distance} = $data->{distance} if exists $data->{distance};
							$loc->{city} = $data->{city} if exists $data->{city};
							$loc->{country} = get_country $data->{country} or die "No country"
								if exists $data->{country};
						}
						else {
							$data->{id} =~ /^\d+$/
								or return $req->reply(400,'{"error":"bad id"}');

							$LOCATIONS{ $data->{id} }
								and return $req->reply(400,'{"error":"bad id"}');

							(exists( $data->{id})
							+ exists( $data->{place})
							+ exists( $data->{country})
							+ exists( $data->{city})
							+ exists( $data->{distance}))
							== 5 or return $req->reply(400,'{"error":"bad fields"}');

							$data->{country} = get_country $data->{country} or die "No country";

							$LOCATIONS{ $data->{id} } = $data;
						}
						return $req->reply(200,'{}');

					}
					elsif($path =~ m{^/visits/(?:(\d+)|(new))$}) {

						my $v = $data;
						my $cond = 0
						if DEBUG;

						if (DEBUG and $cond) {
							p $path;
							p $data;
						}

						if ($1) { # update
							my $vis = $VISITS{$1}
								or return $req->reply(404,'{}');

							if (exists $v->{mark}) {
								$v->{mark} =~ /^[0-5]$/
									or return $req->reply(400,'{"error":"bad mark"}');
								$vis->{mark} = $v->{mark};
							}
							my $resort_loc = 0;
							my $resort_usr = 0;
							if (exists $v->{visited_at}) {
								$v->{visited_at} =~ /^\d+$/
									or return $req->reply(400,'{"error":"bad visited_at"}');
								$vis->{visited_at} = $v->{visited_at};
								$resort_loc = 1;
								$resort_usr = 1;
							}

							if (exists $v->{location} and $vis->{location} != $v->{location}) {
								warn "Move loc $vis->{location} -> $v->{location}" if DEBUG and $cond;

								my $loc = $LOCATIONS{$v->{location}}
									or return $req->reply(400,'{"error":"bad location"}');
								$resort_loc = 0;

								my $oldv = $vis->{location};
								my $newv = $v->{location};

								my $old = $LOCATION_VISITS{ $vis->{location} };
								my $new = $LOCATION_VISITS{ $v->{location} } //= [];

								dump_visits "Before", $old if DEBUG and $cond;
								$vis->{location} = $v->{location};
								# warn sprintf "update location %d -> %d",0+@$old, 0+@$new if ($cond);
								my $ptr;

								for ( 0..$#$old ) {
									if ( $old->[$_]{visit}{id} == $vis->{id} ) {
										$ptr = splice @$old, $_,1, ();
										# warn "removed from $oldv#$_ -> @{[ 0+@$old ]}" if $cond;
										last;
									}
								}
								dump_visits "After", $old if DEBUG and $cond;

								dump_visits "Before", $new if DEBUG and $cond;
								my $pos;
								for ($pos = 0; $pos < @$new; $pos++ ) {
									if ( $new->[$pos]{visit}{visited_at} > $vis->{visited_at} ) {
										# warn "detected position $newv#$pos" if $cond;
										last;
									}
								}
								splice @$new,$pos, 0, $ptr;
								# warn "insert $ptr to $pos -> @{[ 0+@$new ]}" if $cond;
								dump_visits "After", $new if DEBUG and $cond;

								$ptr->{location} = $loc;

								p $ptr if DEBUG and $cond;

							}

							if (exists $v->{user} and $vis->{user} != $v->{user}) {
								my $user = $USERS{$v->{user}}
									or return $req->reply(400,'{"error":"bad user"}');
								$resort_usr = 0;

								my $old = $USER_VISITS{ $vis->{user} };
								my $new = $USER_VISITS{ $v->{user} } //= [];
								$vis->{user} = $v->{user};
								my $ptr;

								for ( 0..$#$old ) {
									if ( $old->[$_]{visit}{id} == $vis->{id} ) {
										$ptr = splice @$old, $_,1, ();
										# warn "removed from $vis->{user}#$_";
										last;
									}
								}
								my $pos;
								for ($pos = 0; $pos < @$new; $pos++ ) {
									if ( $new->[$pos]{visit}{visited_at} > $vis->{visited_at} ) {
										# warn "detected position $pos";
										last;
									}
								}
								# warn "insert $ptr to $pos";
								splice @$new,$pos, 0, $ptr;
								$ptr->{user} = $user;
							}

							if ($resort_usr) {
								my $visits = $USER_VISITS{ $vis->{user} };
								@$visits = sort {
									$a->{visit}{visited_at} <=> $b->{visit}{visited_at}
								} @$visits;
							}
							if ($resort_loc) {
								my $visits = $LOCATION_VISITS{ $vis->{location} };
								@$visits = sort {
									$a->{visit}{visited_at} <=> $b->{visit}{visited_at}
								} @$visits;
							}

							return $req->reply(200,'{}');
						}
						else {
							my $loc = $LOCATIONS{$v->{location}}
								or return $req->reply(400,'{"error":"bad location"}');
							my $usr = $USERS{$v->{user}}
								or return $req->reply(400,'{"error":"bad user"}');

							$data->{id} =~ /^\d+$/
								or return $req->reply(400,'{"error":"bad id"}');

							$VISITS{$v->{id}}
								and return $req->reply(400,'{"error":"id exists"}');

							exists $v->{mark}
								or return $req->reply(400,'{"error":"bad mark"}');
							exists $v->{visited_at}
								or return $req->reply(400,'{"error":"bad visited_at"}');

							$VISITS{$v->{id}} = $v;

							$req->reply(200,'{}');
							AE::postpone {
								my $uvl = {
									user => $usr,
									visit => $v,
									location => $loc,
								};

								my $uv = $USER_VISITS{ $v->{user} } //= [];
								my $lv = $LOCATION_VISITS{ $v->{location} } //= [];
								# dump_visits "Before", $uv if $cond;
								my $pos;
								for ($pos = 0; $pos < @$lv; $pos++) {
									last if $lv->[$pos]{visit}{visited_at} > $v->{visited_at};
								}
								splice @$lv,$pos,0,$uvl;

								for ($pos = 0; $pos < @$uv; $pos++) {
									# warn "$uv->[$pos]{visit}{visited_at} > $v->{visited_at}";
									last if $uv->[$pos]{visit}{visited_at} > $v->{visited_at};
								}
								# warn "U: >>> $pos";
								splice @$uv,$pos,0,$uvl;
								# dump_visits "After", $uv if $cond;
							};
							return;
						}
					}
					else {
						return $req->reply(404,'{}');
					}
					$req->reply(501,'{}');
				}
			};
		}
		return 400, '{}' unless $req->method eq 'GET';

		if ($path =~ m{^/users/(\d+)(/visits|)$}) {
			my $user = $USERS{$1}
				or return 404,'{}';
			unless ($2) {
				$STAT{users}++;
				return 200, $JSON->encode({
					id           => 0+$user->{id},
					email        => $user->{email},
					gender       => $user->{gender},
					first_name   => $user->{first_name},
					last_name    => $user->{last_name},
					birth_date   => 0+$user->{birth_date},
				});
			}
			else {
				$STAT{users_visits}++;
				my $prm = $req->params;
				my @cond;
				if (exists $prm->{fromDate}) {
					return 400,'{}' unless $prm->{fromDate} =~ /^\d+$/;
					push @cond, "\$_->{visit}{visited_at} >= $prm->{fromDate}";
				}
				if (exists $prm->{toDate}) {
					return 400,'{}' unless $prm->{toDate} =~ /^\d+$/;
					push @cond, "\$_->{visit}{visited_at} <= $prm->{toDate}";
				}
				if (exists $prm->{country}) {
					my $country = $COUNTRIES{ fc $prm->{country} };
					return 400,'{"error":"Bad country"}' unless $country;
					push @cond, "\$_->{location}{country} == $country->{id}";
				}
				if (exists $prm->{toDistance}) {
					return 400,'{}' unless $prm->{toDistance} =~ /^\d+$/;
					push @cond, "\$_->{location}{distance} < $prm->{toDistance}";
				}

				$USER_VISITS{ $user->{id} }
					or return 200, $JSON->encode({visits => []});

				my @visits;
				my $filter;
				if (@cond) {
					my $body = 'sub{'.join(' and ', @cond).'}';
					# say $body;
					$filter = eval $body or die $@;
				}
				for($filter ? grep &$filter, @{ $USER_VISITS{ $user->{id} } } : @{ $USER_VISITS{ $user->{id} } } ) {
					push @visits, {
						mark       => 0+$_->{visit}{mark},
						visited_at => 0+$_->{visit}{visited_at},
						place      => $_->{location}{place},
					};
				}
				return 200, $JSON->encode({
					visits => \@visits,
				});
			}
		}
		elsif ($path =~ m{^/locations/(\d+)(/avg|)$}) {
			my $loc = $LOCATIONS{$1}
				or return 404,'{}';
			# say "Location $1 + ".(0+@{ $loc->{visits} });

			unless ($2) {
				# p $loc;
				# p $COUNTRIES{$loc->{country}};
				$STAT{locations}++;
				my $ret = {
					id       => 0+$loc->{id},
					country  => $COUNTRY_ID{$loc->{country}}{name},
					city     => $loc->{city},
					distance => 0+$loc->{distance},
					place    => $loc->{place},
				};
				# p $ret;
				return 200, $JSON->encode($ret);
			}
			else {
				my $prm = $req->params;
				$STAT{locations_avg}++;

				my $now = Time::Moment->now;
				my @cond;
				if (exists $prm->{fromDate}) {
					return 400,'{}' unless $prm->{fromDate} =~ /^\d+$/;
					push @cond, "\$_->{visit}{visited_at} >= $prm->{fromDate}";
				}
				if (exists $prm->{toDate}) {
					return 400,'{}' unless $prm->{toDate} =~ /^\d+$/;
					push @cond, "\$_->{visit}{visited_at} <= $prm->{toDate}";
				}

				if (exists $prm->{fromAge}) {
					return 400,'{}' unless $prm->{fromAge} =~ /^\d+$/;
					my $older = $now->minus_years( $prm->{fromAge} )->epoch;
					push @cond, "\$_->{user}{birth_date} <= $older";
				}
				if (exists $prm->{toAge}) {
					return 400,'{}' unless $prm->{toAge} =~ /^\d+$/;
					my $younger = $now->minus_years( $prm->{toAge} )->epoch;
					push @cond, "\$_->{user}{birth_date} > $younger";
				}
				if (exists $prm->{gender}) {
					return 400,'{}' unless $prm->{gender} =~ /^(f|m)$/;
					push @cond, "\$_->{user}{gender} eq '$prm->{gender}'";
				}
				$LOCATION_VISITS{ $loc->{id} }
					or return 200, $JSON->encode({ avg => 0 });

				my $sum = 0;
				my $cnt = 0;
				my $filter;
				if (@cond) {
					my $body = 'sub{'.join(' and ', @cond).'}';
					$filter = eval $body or die $@;
				}
				for ( $filter ? grep &$filter, @{ $LOCATION_VISITS{ $loc->{id} } } : @{ $LOCATION_VISITS{ $loc->{id} } } ) {
					$sum += $_->{visit}{mark};
					$cnt++;
				}
				return 200, $JSON->encode({
					avg => $cnt && (int($sum/$cnt*1e5+0.5)/1e5) || 0,
				})
			}
		}
		elsif ($path =~ m{^/visits/(\d+)$}) {
			$STAT{visits}++;
			my $visit = $VISITS{$1}
				or return 404,'{}';
			return 200, $JSON->encode({
				id          => 0+$visit->{id},
				location    => 0+$visit->{location},
				user        => 0+$visit->{user},
				visited_at  => 0+$visit->{visited_at},
				mark        => 0+$visit->{mark},
			});
		}
		else {
			return 404,'{}', headers => { connection => 'close' };
		}
	}
);
warn "Listen ",join (':', $srv->listen), "\n";
$srv->accept;

sub stop {
	warn "END: ".$JSON->encode(\%STAT)."\n";
	$srv->graceful(sub {});
	EV::unloop;
}

my $i = EV::signal INT => \&stop;
my $t = EV::signal TERM => \&stop;

EV::loop;
exit 0;
