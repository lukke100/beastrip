#!/usr/bin/env perl
use Modern::Perl '2012';
our $VERSION = '0.1';

use utf8;
use autodie qw{:all};
use open qw{:std :encoding(UTF-8)};
use Carp;
use English qw{-no_match_vars};
use HTML::FormatText;
use HTML::TreeBuilder;
use List::Util qw{any uniqstr};
use Set::CrossProduct;

use lib 'lib';
use CallDispatch;

if (not caller) {
	main(@ARGV);
}

sub main {
	my @creatures;

	for (@ARG) {
		#STDERR->say("parsing '$ARG'");

		my $creature = parsefile($ARG);

		fixorganization($creature);

		push @creatures, $creature;
	}

	STDERR->say('printing environment rows');

	for (@creatures) {
		my $neighbors = countneighbors($ARG, @creatures);

		$ARG->{ratio} = @creatures / $neighbors;

		for (creature2ecorows($ARG)) {
			STDOUT->say(join "\t", @{$ARG});
		}
	}

	return;
}

sub countneighbors {
	my ($creature, @candidates) = @ARG;
	my $result = 0;

	if (not exists $creature->{environment}) {
		return scalar @candidates;
	}

	CANDIDATE: for (@candidates) {
		my @canenv = [qw{any any any}, q{}];

		if (exists $ARG->{environment}) {
			@canenv = @{$ARG->{environment}};
		}

		for (@canenv) {
			my $env1 = $ARG;

			for (@{$creature->{environment}}) {
				my $env2 = $ARG;

				if (enveq($env1, $env2)) {
					++$result;
					next CANDIDATE;
				}
			}
		}
	}

	return $result;
}

sub enveq {
	my ($env1, $env2) = @ARG;

	for (0 .. 2) {
		next if $env1->[$ARG] eq $env2->[$ARG];
		next if $env1->[$ARG] eq q{};
		next if $env1->[$ARG] eq 'any';
		next if $env2->[$ARG] eq q{};
		next if $env2->[$ARG] eq 'any';

		return 0;
	}

	return 1;
}

sub creature2ecorows {
	my ($creature) = @ARG;
	my @sources;

	if (exists $creature->{sources}) {
		for (@{$creature->{sources}}) {
			my ($book, $page) = @{$ARG};

			push @sources, "$book pg. $page";
		}
	}

	my @environment  = [q{}, q{}, q{}, q{}];
	my $sources      = join ', ', @sources;
	my $organization = q{};

	if (exists $creature->{environment}) {
		@environment = @{$creature->{environment}};
	}

	my @results;

	for (@environment) {
		my ($climate, $terrain, $plane, $special) = @{$ARG};
		my @row;

		push @row, $creature->{name};
		push @row, q{=} . $creature->{CR};
		push @row, $creature->{alignment} || q{};
		push @row, $creature->{type}      || q{};
		push @row, $creature->{subtypes}  || q{};
		push @row, $climate, $terrain, $plane, $special;
		push @row, $sources;
		push @row, sprintf '%.2f%%', 100 * $creature->{ratio};

		push @results, \@row;
	}

	return @results;
}

sub parsefile {
	my ($path) = @ARG;

	my $formatter = HTML::FormatText->new(lm => 0, rm => 9999);
	my $htmltree  = HTML::TreeBuilder->new;

	open my $file, '<', $path;
	$htmltree->parse_file($file);
	close $file;

	my $body = $htmltree->look_down(
		_tag => 'span',
		id   => 'ctl00_MainContent_DataListFeats_ctl00_Label1',
		);

	$body->normalize_content;

	for ($body->look_down(_tag => 'sup')) {
		if (not $ARG->content_list) {
			next;
		}

		$ARG->unshift_content('(');
		$ARG->push_content(')');
	}

	my $lines = $formatter->format($body);
	$lines =~ s/’/'/gmsx;
	$lines =~ s/[\r\n]{2,}/\n/gmsx;
	$lines =~ s/(\p{Lu}\p{Ll}|\p{Lu}\p{Ll})/\L$1/gmsx;
	$lines =~ s/\B—\B/--/gmsx;
	$lines =~ s/—/ -- /gmsx;
	$lines =~ s/–/-/gmsx;

	$lines =~ s/\[IMAGE\]//gmsx;
	$lines =~ s/\bR'lyeh\b/r'lyeh/gmsx;

	my $dp = mkdpintro();
	my %dp = (
		'defense'           => mkdpdefense(),
		'offense'           => mkdpoffense(),
		'statistics'        => mkdpstatistics(),
		'ecology'           => mkdpecology(),
		'environment'       => mkdpecology(),
		'special abilities' => mkdpspecialabilities(),
		'description'       => CallDispatch->new,
		'base statistics'   => CallDispatch->new,
		);

	my @letrepeat = qw{ecology environment};
	my @oldsections;
	my %creature;

	for my $line (split /\n/msx, $lines) {
		if (exists $dp{$line}) {
			$dp = $dp{$line};

			if (not any { $line eq $ARG } @letrepeat) {
				delete $dp{$line};
				push @oldsections, $line;
			}

			next;
		}

		my @results;

		for ($dp->apply($line)) {
			if (defined $ARG) {
				push @results, $ARG;
			}
		}

		if (@results > 1) {
			croak "Multiple parsers match line '$line'";
		}

		if (not @results) {
			if (not exists $creature{extra}) {
				$creature{extra} = q{};
			}

			$creature{extra} .= "$line\n";
		}

		if (not attrmerge(\%creature, $results[0])) {
			carp "Can't merge data from '$line'";
		}
	}

	if (exists $creature{sources}) {
		@{$creature{sources}} = nub2d(@{$creature{sources}});
	}

	if (exists $creature{environment}) {
		@{$creature{environment}} = nub2d(@{$creature{environment}});
	}

	if ($creature{CR} eq q{-}) {
		$creature{CR} = 0;
	}

	return \%creature;
}

sub mkdpintro {
	my $dp = CallDispatch->new;

	my $name = qr/(?<name>.{1,60})/msx;
	my $cr   = qr/CR[ ](?<CR>[\d\/]+|-)/msx;
	$dp->add(re2sub(qr/\A$name[ ]$cr\z/msx));

	$dp->add(\&parsesourcesline);
	$dp->add(re2sub(qr/\AXP[ ](?<XP>[\d,]+)\z/msx));

	my $alignment  = qr/[LC][GNE]|N[GE]?/msx;
	my $alignments = qr{
		(?:usually[ ])?
		(?:$alignment)
		(?:[ ]or[ ](?:$alignment))?
	}msx;

	my @oddaligns = (
		'any alignment',
		'any alignment (same as creator)',
		'N (but see below)',
	);
	my $oddaligns = join q{|}, map { quotemeta $ARG } @oddaligns;

	my @sizes = qw{
		fine diminutive tiny small medium
		large huge gargantuan colossal
		};
	my $size = join q{|}, @sizes;

	my @types = (
		'aberration', 'animal', 'construct', 'dragon', 'fey',
		'humanoid', 'magical beast', 'monstrous humanoid',
		'ooze', 'outsider', 'plant', 'undead', 'vermin',
		);
	my $type = join q{|}, map { quotemeta $ARG } @types;

	my $info = qr{
		   (?<alignment>$alignments|$oddaligns)
		[ ](?<size>$size)
		[ ](?<type>$type)
	}msx;

	$dp->add(re2sub(qr/\A$info\z/msx));
	$dp->add(re2sub(qr/\Aalways[ ]$info\z/msx));
	$dp->add(re2sub(qr/\A$info[ ][(](?<subtypes>.+)[)]\z/msx));
	$dp->add(re2sub(qr/\Aalways[ ]$info[ ][(](?<subtypes>.+)[)]\z/msx));

	my $init   = qr/init[ ](?<init>[+-]\d+)/msx;
	my $senses = qr/senses[ ](?<senses>[^;]+)/msx;
	my $percep = qr/perception[ ](?<perception>[+-]\d+)/msx;
	$dp->add(re2sub(qr/\A$init;[ ]$senses;[ ]$percep\z/msx));

	return $dp;
}

sub mkdpdefense {
	my $dp = CallDispatch->new;

	$dp->add(str2ignore('defense'));

	my $ac   = qr/AC[ ](?<AC>\d+)/msx;
	my $tac  = qr/touch[ ](?<touch>\d+)/msx;
	my $ffac = qr/flat-footed[ ](?<flatfooted>\d+)/msx;
	my $mods = qr/[(](?<ACmods>.+)[)]/msx;
	$dp->add(re2sub(qr/\A$ac,[ ]$tac,[ ]$ffac[ ]$mods\z/msx));

	my $hp = qr/hp[ ](?<hp>\d+)/msx;
	my $hd = qr/[(](?:\d+[ ]HD;[ ])?(?<HD>[d\d+-]+)[)]/msx;
	$dp->add(re2sub(qr/\A$hp[ ]$hd\z/msx));

	my $fort = qr/fort[ ](?<fort>[+-]\d+)/msx;
	my $ref  = qr/ref[ ](?<ref>[+-]\d+)/msx;
	my $will = qr/will[ ](?<will>[+-]\d+)/msx;
	$dp->add(re2sub(qr/\A$fort,[ ]$ref,[ ]$will\z/msx));

	my @elems   = qw{acid cold electricity fire sonic};
	my $elems   = join q{|}, @elems;
	my $resist  = qr/(?:$elems)[ ]\d+/msx;
	my $resists = qr/(?<resist>$resist(?:,[ ]$resist)*)/msx;
	$dp->add(re2sub(qr/\Aresist[ ]$resists\z/msx));

	$dp->add(re2sub(qr/\ASR[ ](?<SR>\d+(?:[ ][(][^()]+[)])?)\z/msx));

	return $dp;
}

sub mkdpoffense {
	my $dp = CallDispatch->new;

	$dp->add(str2ignore('offense'));

	my $feet  = qr/\d+[ ]ft[.]/msx;
	my $speed = qr/speed[ ](?<speed>$feet)/msx;
	my $armor = qr/[(](?<armorspeed>$feet)[ ]in[ ]armor[)]/msx;
	my $swim  = qr/swim[ ](?<swim>$feet)/msx;
	my $space = qr/space[ ](?<space>$feet)/msx;
	my $reach = qr/reach[ ](?<reach>$feet(?:[ ][(][^()]+[)])?)/msx;
	$dp->add(re2sub(qr/\A$speed\z/msx));
	$dp->add(re2sub(qr/\A$speed[ ]$armor\z/msx));
	$dp->add(re2sub(qr/\A$speed,[ ]$swim\z/msx));
	$dp->add(re2sub(qr/\A$space,[ ]$reach\z/msx));

	my @flymans = qw{clumsy poor average good perfect};
	my $flymans = join q{|}, @flymans;
	my $flyman   = qr/[(](?<maneuverability>$flymans)[)]/msx;

	my $fly = qr/fly[ ](?<fly>$feet)/msx;
	$dp->add(re2sub(qr/\A$speed,[ ]$fly[ ]$flyman\z/msx));

	$dp->add(re2sub(qr/\Amelee[ ](?<melee>.+)\z/msx));
	$dp->add(re2sub(qr/\Aranged[ ](?<ranged>.+)\z/msx));
	$dp->add(re2sub(qr/\Aspecial[ ]attacks[ ](?<specialattacks>.+)\z/msx));

	return $dp;
}

sub mkdpstatistics {
	my $dp = CallDispatch->new;

	$dp->add(str2ignore('statistics'));

	my @stats   = qw{str dex con int wis cha};
	my @statres = map { qr/$ARG[ ](?<$ARG>\d+|--)/msx } @stats;
	my $stats   = join qr/,[ ]/msx, @statres;
	$dp->add(re2sub(qr/\A$stats\z/msx));

	my $bab = qr/base[ ]atk[ ](?<BAB>[+-]\d+)/msx;
	my $cmb = qr/CMB[ ](?<CMB>[+-]\d+(?:[ ][(][^()]+[)])?)/msx;
	my $cmd = qr/CMD[ ](?<CMD>\d+(?:[ ][(][^()]+[)])?)/msx;
	$dp->add(re2sub(qr/\A$bab;[ ]$cmb;[ ]$cmd\z/msx));

	$dp->add(re2sub(qr/\Afeats[ ](?<feats>.+)\z/msx));
	$dp->add(re2sub(qr/\Askills[ ](?<skills>.+)\z/msx));
	$dp->add(re2sub(qr/\Alanguages[ ](?<languages>.+)\z/msx));
	$dp->add(re2sub(qr/\ASQ[ ](?<SQ>.+)\z/msx));

	return $dp;
}

sub mkdpecology {
	my $dp = CallDispatch->new;

	$dp->add(str2ignore('ecology'));
	$dp->add(str2ignore('environment'));
	$dp->add(\&parseecologyline);
	$dp->add(\&parseenvironmentline);
	$dp->add(\&parseorganizationline);
	$dp->add(re2sub(qr/\Atreasure[ ](?<treasure>.+)\z/msx));

	return $dp;
}

sub mkdpspecialabilities {
	my $dp = CallDispatch->new;

	$dp->add(str2ignore('special abilities'));
	$dp->add(\&parsespecialabilityline);

	return $dp;
}

sub parsesourcesline {
	my ($line) = @ARG;

	if ($line =~ /\Asource[ ](.+)\z/msx) {
		my $tmp = { sources => [] };
		my $raw = $1;

		$raw =~ s/pathfinder[ ]RPG[ ]bestiary/bestiary 1/gmsx;

		while ($raw =~ s/\A(.+?)[ ]pg[.][ ](\d+),[ ]//msx) {
			push @{$tmp->{sources}}, [$1, $2];
		}

		if ($raw =~ /\A(.+)[ ]pg[.][ ](\d+)\z/msx) {
			push @{$tmp->{sources}}, [$1, $2];
			return $tmp;
		}

		if ($raw eq 'blood of the coven') {
			push @{$tmp->{sources}}, [$raw, q{--}];
			return $tmp;
		}

		carp "Can't parse sources: '$line'";
	}

	return;
}

sub parseenvironmentline {
	my ($line) = @ARG;
	my $ecore  = qr/(?:ecology|environment)[ ].+?/msx;
	my $orgre  = qr/organization[ ].+?/msx;
	my $lootre = qr/treasure[ ].+/msx;

	if ($line =~ /\A$ecore[ ]$orgre[ ]$lootre\z/msx) {
		return;
	}

	if ($line =~ /\Aenvironment[ ](.+)\z/msx) {
		my @env = parseenvironment($1);

		if (not @env) {
			croak "Can't parse line '$line'";
		}

		return { environment => \@env };
	}

	return;
}

sub parseorganizationline {
	my ($line) = @ARG;

	if ($line =~ /\Aorganization[ ](.+)\z/msx) {
		my @org = parseorganization($1);

		if (not @org) {
			croak "Can't parse organization '$line'";
		}

		return { organization => \@org };
	}

	return;
}

sub parseecologyline {
	my ($line) = @ARG;
	my $ecore  = qr/(?:ecology|environment)[ ](.+?)/msx;
	my $orgre  = qr/organization[ ](.+?)/msx;
	my $lootre = qr/treasure[ ](.+)/msx;

	if ($line =~ /\A$ecore[ ]$orgre[ ]$lootre\z/msx) {
		my ($env, $org, $loot) = ($1, $2, $3);
		my @env = parseenvironment($env);
		my @org = parseorganization($org);
		my $tmp = {};

		if (not @env) {
			croak "Can't parse line '$line'";
		}

		$tmp->{environment}  = \@env;
		$tmp->{organization} = \@org;
		$tmp->{treasure}     = $loot;

		return $tmp;
	}

	return;
}

sub parsespecialabilityline {
	my ($line) = @ARG;

	if ($line =~ /\A([^()]+[ ][(](?:ex|su|sp)[)][ ].+)\z/msx) {
		return { specialabilities => [$1] };
	}

	return;
}

sub attrmerge {
	my ($target, $source) = @ARG;

	for (keys %{$source}) {
		if (not exists $target->{$ARG}) {
			next;
		}

		if (ref $target->{$ARG} eq 'ARRAY'
		and ref $source->{$ARG} eq 'ARRAY') {
			next;
		}

		if ($target->{$ARG} eq $source->{$ARG}) {
			next;
		}

		return 0;
	}

	for (keys %{$source}) {
		if (ref $target->{$ARG} eq 'ARRAY'
		and ref $source->{$ARG} eq 'ARRAY') {
			push @{$target->{$ARG}}, @{$source->{$ARG}};
			next;
		}

		$target->{$ARG} = $source->{$ARG};
	}

	return 1;
}

sub re2sub {
	my ($regex) = @ARG;

	return sub {
		my ($text) = @ARG;

		if ($text =~ $regex) {
			return { %LAST_PAREN_MATCH };
		}

		return;
	};
}

sub str2ignore {
	my ($str) = @ARG;

	return sub {
		my ($text) = @ARG;

		if ($text eq $str) {
			return {};
		}

		return;
	};
}

sub nub2d {
	my (%seen, @results);

	for (@ARG) {
		my $key = join "\t", @{$ARG};

		if (exists $seen{$key}) {
			next;
		}

		$seen{$key} = undef;
		push @results, $ARG;
	}

	return @results;
}

sub parseenvironment {
	my ($str) = @ARG;

	my @climates = qw{cold temperate tropical warm hot};
	my %climates = (
		'non-cold' => [qw{temperate tropical warm}],
		);

	my $climate = join
		q{|},
		map { quotemeta $ARG } @climates, keys %climates;

	my $climates = qr{(
		(?:$climate)
		(?:,[ ](?-1)|,?[ ](?:and|or)[ ](?:$climate))?
	)}msx;

	my @terrains = qw{
		coastlines deserts forests hills lakes marshes mountains oceans
		plains rivers ruins skies swamps underground urban vacuum

		badlands glaciers islands jungles volcanoes
		};

	my %terrains = (
		# typical groups
		'aboveground natural area' => [qw{
			coastlines deserts forests hills
			marshes mountains plains swamps
			}],
		aquatic       => [qw{lakes oceans rivers}],
		freshwater    => [qw{lakes rivers}],
		'fresh water' => [qw{lakes rivers}],
		land          => [qw{
			coastlines deserts forests hills
			marshes mountains plains swamps urban
			}],
		underwater => [qw{lakes oceans rivers}],
		water      => [qw{lakes oceans rivers}],
		waters     => [qw{lakes oceans rivers}],
		wetlands   => [qw{marshes swamps}],
		wilderness => [qw{
			coastlines deserts forests hills
			marshes mountains plains swamps
			}],
		woodlands  => [qw{forests swamps}],

		# replacements
		air                  => ['skies'],
		coast                => ['coastlines'],
		coastal              => ['coastlines'],
		coastline            => ['coastlines'],
		coasts               => ['coastlines'],
		desert               => ['deserts'],
		forest               => ['forests'],
		hill                 => ['hills'],
		island               => ['islands'],
		jungle               => ['jungles'],
		lake                 => ['lakes'],
		marsh                => ['marshes'],
		mountain             => ['mountains'],
		ocean                => ['oceans'],
		'outer space'        => ['vacuum'],
		plain                => ['plains'],
		river                => ['rivers'],
		ruin                 => ['ruins'],
		saltwater            => ['oceans'],
		shore                => ['coastlines'],
		shorelines           => ['coastlines'],
		sky                  => ['skies'],
		swamp                => ['swamps'],
		'volcanic mountains' => ['volcanoes'],
		volcano              => ['volcanoes'],
		wastelands           => ['badlands'],
		);

	my $terrain = join
		q{|},
		map { quotemeta $ARG } @terrains, keys %terrains;

	my $terrains = qr{(
		(?:$terrain)
		(?:,[ ](?-1)|,?[ ](?:and|or)[ ](?:$terrain))?
	)}msx;

	my @planes = (
		'material plane', 'ethereal plane',
		'first world', 'shadow plane',
		'negative energy plane', 'positive energy plane',
		'plane of air', 'plane of earth',
		'plane of fire', 'plane of water',
		'astral plane', 'heaven', 'nirvana', 'elysium', 'axis',
		'boneyard', 'maelstrom', 'hell', 'abaddon', 'abyss',
		'akashic record', 'cynosure', 'dead vault',
		'dimension of dreams', 'dimension of time',
		'hao jin tapestry', 'harrowed realm', 'jandelay',
		'leng', 'xibalba', 'r\'lyeh', 'river styx',
		);

	my @goodplanes = qw{heaven nirvana elysium cynosure};
	my @evilplanes = (
		'abaddon', 'abyss', 'dead vault', 'hell', 'leng', 'xibalba',
		);

	my @outerplanes = (
		'astral plane', 'heaven', 'nirvana', 'elysium', 'axis',
		'boneyard', 'maelstrom', 'hell', 'abaddon', 'abyss',
		);

	my %planes = (
		'elemental planes' => [
			'plane of air', 'plane of earth',
			'plane of fire', 'plane of water',
			],
		'evil-aligned plane' => \@evilplanes,
		'evil outer plane'   => [qw{abaddon abyss hell}],
		'evil plane'         => \@evilplanes,
		'evil planes'        => \@evilplanes,
		'extraplanar'        => [
			grep { $ARG ne 'material plane' } @planes
			],
		'good-aligned plane'  => \@goodplanes,
		'good-aligned planes' => \@goodplanes,
		'lawful plane'        => [qw{heaven axis hell jandelay}],
		'outer plane'         => \@outerplanes,
		'outer planes'        => \@outerplanes,

		# replacements
		'abbadon'               => ['abaddon'],
		'limbo'                 => ['maelstrom'],
		'material plane only'   => ['material plane'],
		'outer plane (abaddon)' => ['abaddon'],
		'primal land of fey'    => ['first world'],
		'plane of shadow'       => ['shadow plane'],
		'pharasma\'s boneyard'  => ['boneyard'],
		'purgatory'             => ['boneyard'],
		'the abyss'             => ['abyss'],
		'the boneyard'          => ['boneyard'],
		'the first world'       => ['first world'],
		);

	my $plane  = join q{|}, map { quotemeta $ARG } @planes, keys %planes;
	my $planes = qr{(
		(?:$plane)
		(?:,[ ](?-1)|,?[ ](?:and|or)[ ](?:$plane))?
	)}msx;

	my @specials = (
		'aballon', 'andoran', 'arcadia', 'battlefields',
		'beneath kaer maga', 'blood vale', 'casmaron', 'castrovel',
		'cheliax', 'crystilan (xin-edasseril)', 'darklands',
		'deep tolguth', 'dominion of the black ships', 'dragonfall',
		'during storms', 'except water', 'field of maidens',
		'former azlanti ruin', 'garund', 'graveyards',
		'grungir forest', 'hold of belkzen', 'irrisen',
		'ivory labyrinth', 'kaer maga', 'kalexcourt', 'katapesh',
		'korvosa', 'kurnugia', 'lightning storms',
		'living hosts in any climate', 'magnimar', 'mediogalti island',
		'mwangi expanse', 'near ghouls', 'necropolis of nogortha',
		'nirmathas', 'nuat', 'numeria', 'osirion', 'pumpkin patches',
		'quantium', 'rahadoum', 'razmiran', 'sekatar-seraktis',
		'sewers', 'sightless sea', 'sothis', 'spellscar desert',
		'tanglebriar', 'thassilon', 'thassilonian runes',
		'the mana wastes', 'the storval deep', 'the worldwound',
		'tar seeps', 'trenches', 'ustalav', 'varisia', 'vudra',
		'waterfalls', 'yoha\'s graveyard',
		);

	my %specials = (
		);

	my $special = join
		q{|},
		map { quotemeta $ARG } @specials, keys %specials;

	my $specials = qr{(
		(?:$special)
		(?:,[ ](?-1)|,?[ ](?:and|or)[ ](?:$special))?
	)}msx;

	my $dp = CallDispatch->new;

	$dp->add(re2sub(qr/\A(?<climate>$climates)\z/msx));
	$dp->add(re2sub(qr/\A(?<plane>$planes)\z/msx));
	$dp->add(re2sub(qr/\A(?<terrain>$terrains)\z/msx));
	$dp->add(re2sub(qr/\A(?<special>$specials)\z/msx));
	$dp->add(re2sub(qr{\A
		(?<terrain>$terrains)
		[ ]
		[(](?<plane>$planes)[)]
	\z}msx));

	$dp->add(re2sub(qr{\A
		(?<terrain>$terrains)
		[ ]
		[(](?<special>$specials)[)]
	\z}msx));

	$dp->add(re2sub(qr/\A(?<climate>(?<terrain>any))\z/msx));
	$dp->add(re2sub(qr/\Aany[ ][(](?<climate>$climates)[)]\z/msx));
	$dp->add(re2sub(qr/\Aany[ ][(](?<terrain>$terrains)[)]\z/msx));
	$dp->add(re2sub(qr/\Aany[ ][(](?<plane>$planes)[)]\z/msx));
	$dp->add(re2sub(qr/\Aany[ ][(](?<special>$specials)[)]\z/msx));

	$dp->add(re2sub(qr{\A
		any
		[ ]
		[(]usually[ ](?<terrain>$terrains)[)]
	\z}msx));

	$dp->add(re2sub(qr{\A
		any
		[ ]
		[(](?<plane>$planes);[ ](?<special>$specials)[)]
	\z}msx));

	$dp->add(re2sub(qr{\A
		any[ ]land
		[ ]
		[(](?<terrain>$terrains)[)]
	\z}msx));

	$dp->add(re2sub(qr{\A
		any[ ]land
		[ ]
		[(]usually[ ](?<terrain>$terrains)[)]
	\z}msx));

	my $anyclimate = qr/any[ ](?<terrain>$terrains)/msx;
	my $anyterrain = qr/any[ ](?<climate>$climates)/msx;
	my $anyplane   = qr/any[ ](?<plane>$planes)/msx;
	my $anyspecial = qr/any[ ](?<special>$specials)/msx;
	my $material   = qr/(?<climate>$climates)[ ](?<terrain>$terrains)/msx;

	$dp->add(re2sub(qr/\A$anyclimate\z/msx));
	$dp->add(re2sub(qr/\A$anyclimate[ ][(](?<plane>$planes)[)]\z/msx));
	$dp->add(re2sub(qr/\A$anyclimate[ ][(](?<special>$specials)[)]\z/msx));
	$dp->add(re2sub(qr/\A$anyterrain\z/msx));
	$dp->add(re2sub(qr/\A$anyterrain[ ][(](?<plane>$planes)[)]\z/msx));
	$dp->add(re2sub(qr/\A$anyterrain[ ][(](?<special>$specials)[)]\z/msx));
	$dp->add(re2sub(qr/\A$anyplane\z/msx));
	$dp->add(re2sub(qr/\A$anyspecial\z/msx));

	$dp->add(re2sub(qr/\A$material\z/msx));
	$dp->add(re2sub(qr/\A$material[ ][(](?<plane>$planes)[)]\z/msx));
	$dp->add(re2sub(qr/\A$material[ ][(](?<special>$specials)[)]\z/msx));
	$dp->add(re2sub(qr/\Aany[ ]$material\z/msx));
	$dp->add(re2sub(qr/\Aany[ ]$material[ ][(](?<plane>$planes)[)]\z/msx));

	my @results;

	for ($dp->apply($str)) {
		if (defined $ARG) {
			push @results, $ARG;
		}
	}

	if (@results > 1) {
		croak "Multiple parsers match environment '$str'";
	}

	if (@results == 1) {
		my $result = $results[0];

		my @climatelist = splitenvironment(
			$result->{climate} || 'any',
			\%climates, [@climates, 'any'],
			);

		my @terrainlist = splitenvironment(
			$result->{terrain} || 'any',
			\%terrains, [@terrains, 'any'],
			);

		my @planelist = splitenvironment(
			$result->{plane} || 'any',
			\%planes, [@planes, 'any'],
			);

		my @speciallist = splitenvironment(
			$result->{special} || q{},
			\%specials, [@specials, q{}],
			);

		my $cross = Set::CrossProduct->new([
			\@climatelist, \@terrainlist,
			\@planelist, \@speciallist,
			]);

		return $cross->combinations;
	}

	my %fallback = (
		'any (ghahazi, abyss)' => [[qw{any any abyss ghahazi}]],
		'any (graveyards or the boneyard)' => [
			[qw{any any any},       'graveyards'],
			[qw{any any boneyard}, q{}],
			],
		'any (haunted sites or ruins)' => [
			[qw{any any   any}, 'haunted sites'],
			[qw{any ruins any}, q{}],
			],
		'any (ruins or graveyards)' => [
			[qw{any ruins any}, q{}],
			[qw{any any   any}, q{graveyards}],
			],
		'any (terrestrial vacuum)' => [
			[qw{any vacuum any}, 'terrestrial'],
			],
		'any blighted land' => [
			[qw{any coastlines any}, 'blighted'],
			[qw{any deserts    any}, 'blighted'],
			[qw{any forests    any}, 'blighted'],
			[qw{any hills      any}, 'blighted'],
			[qw{any marshes    any}, 'blighted'],
			[qw{any mountains  any}, 'blighted'],
			[qw{any plains     any}, 'blighted'],
			[qw{any swamps     any}, 'blighted'],
			],
		'any cold (the world\'s moon or outer space)' => [
			[qw{cold vacuum any}, 'the world\'s moon'],
			[qw{cold vacuum any}, q{}],
			],
		'any desert or elemental plane' => [
			['any', 'deserts', 'any',            q{}],
			['any', 'any',     'plane of air',   q{}],
			['any', 'any',     'plane of earth', q{}],
			['any', 'any',     'plane of fire',  q{}],
			['any', 'any',     'plane of water', q{}],
			],
		'any plain or battlefield' => [
			[qw{any plains any}, q{}],
			[qw{any any    any   battlefield}],
			],
		'any temperate or underground' => [
			[qw{temperate any         any}, q{}],
			[qw{any       underground any}, q{}],
			],
		'any temperate or warm forest or plains, or urban' => [
			[qw{temperate forests any}, q{}],
			[qw{temperate plains  any}, q{}],
			[qw{warm      forests any}, q{}],
			[qw{warm      plains  any}, q{}],
			[qw{any       urban   any}, q{}],
			],
		'any temperate, warm, or urban' => [
			[qw{temperate any   any}, q{}],
			[qw{warm      any   any}, q{}],
			[qw{any       urban any}, q{}],
			],
		'any underground or warm deserts' => [
			[qw{any  underground any}, q{}],
			[qw{warm deserts     any}, q{}],
			],
		'any water (coastal)' => [
			[qw{any lakes  any}, 'coastal'],
			[qw{any oceans any}, 'coastal'],
			[qw{any rivers any}, 'coastal'],
			],
		'cold forests or tundra' => [
			[qw{cold forests any}, q{}],
			[qw{cold deserts any}, 'tundra'],
			],
		'cold mountainous coastlines' => [
			[qw{cold coastlines any}, q{mountainous}],
			],
		'desert and warm plains' => [
			[qw{any  deserts any}, q{}],
			[qw{warm plains  any}, q{}],
			],
		'gas giants or vacuum' => [
			[qw{any skies  any}, 'gas giants'],
			[qw{any vacuum any}, q{}],
			],
		'hell, ramlock\'s hallow (demiplane), desert' => [
			[qw{any any     hell},             q{}],
			[qw{any any},  'ramlock\' hallow', q{}],
			[qw{any deserts any},              q{}],
			],
		'tropical forest or any urban' => [
			[qw{tropical forests any}, q{}],
			[qw{any      urban   any}, q{}],
			],
		'temperate forest and plains (usually coastal regions)' => [
			[qw{temperate forests    any}, q{}],
			[qw{temperate plains     any}, q{}],
			[qw{temperate coastlines any}, q{}],
			],
		'temperate forests or plains (usually coastal regions)', => [
			[qw{temperate forests    any}, q{}],
			[qw{temperate plains     any}, q{}],
			[qw{temperate coastlines any}, q{}],
			],
		'temperate mountain valleys' => [
			[qw{temperate mountains any}, 'valleys'],
			],
		'temperate plains, rocky hills, and underground' => [
			[qw{temperate plains      any}, q{}],
			[qw{temperate hills       any}, 'rocky'],
			[qw{temperate underground any}, q{}],
			],
		'temperate underground or deep forest' => [
			[qw{temperate underground any}, q{}],
			[qw{temperate forests     any}, 'deep forests'],
			],
		'volcanic underground' => [
			[qw{any volcanoes any}, 'underground'],
			],
		'warm forests or warm ruins' => [
			[qw{warm forests any any}, q{}],
			[qw{warm ruins   any any}, q{}],
			],
		'warm lakes or ponds' => [
			[qw{warm lakes any}, q{}],
			[qw{warm any   any}, 'ponds'],
			],
		);

	if (exists $fallback{$str}) {
		return @{$fallback{$str}};
	}

	croak "Can't parse environment '$str'";
}

sub splitenvironment {
	my ($str, $map, $types) = @ARG;
	my @results = $str;
	my @types   = @{$types};
	my %map     = %{$map};

	while (1) {
		if (any { exists $map{$ARG} } @results) {
			my @newresults;
			my @oldkeys;

			for (@results) {
				if (exists $map{$ARG}) {
					push @newresults, @{$map{$ARG}};
					push @oldkeys, $ARG;
				} else {
					push @newresults, $ARG;
				}
			}

			@results = @newresults;
			delete @map{@oldkeys};
			next;
		}

		my $split = qr/(?:,[ ](?:and|or)|[ ](?:and|or)|,)[ ]/msx;

		if (any { m/$split/msx } @results) {
			@results = map { split /$split/msx } @results;
			next;
		}

		last;
	}

	for my $result (@results) {
		if (not any { $result eq $ARG } @types) {
			carp "Unknown environment '$result'";
		}
	}

	return @results;
}

sub parseorganization {
	my ($str)  = @ARG;
	my $namere = qr/\w+(?:[ ]\w+)*?/msx;
	my $descre = qr/([(](?:[^()]++|(?-1))+[)])/msx;
	my $orgre  = qr/($namere)(?:[ ]($descre))?/msx;
	my $split  = qr/(?:,[ ](?:and|or)|[ ](?:and|or)|,)[ ]/msx;

	$str =~ s/\bsolitary[ ]of[ ]coven\b/solitary or coven/msx;
	$str =~ s/\b($namere),[ ]([(]\d+-\d+[)])/$1 $2/gmsx;
	$str =~ s/([(]\d+-\d+),[ ](including|plus)/$1 $2/gmsx;
	$str =~ s/[(](\d+)-[ ]+(\d+)[)]/($1-$2)/gmsx;
	$str =~ s/\bseugathi[(]B2[)]/seugathi/gmsx;
	$str =~ s/[(]([^()]+)\z/($1)/msx;
	$str =~ s/[.,]\z//msx;

	my $pos = 0;
	my @orgs;

	while ($str =~ /\G($namere)(?:[ ]($descre))?(?:$split)/gmsx) {
		push @orgs, [$1, defined $2? $2 : q{}];
		$pos = pos $str;
	}

	pos $str = $pos;

	if ($str =~ /\G($namere)(?:[ ]($descre))?\z/msx) {
		push @orgs, [$1, defined $2? $2 : q{}];
	} else {
		croak "Can't parse organization '$str'";
	}

	my %names = (
		any      => ['any',      1, q{}, q{}],
		single   => ['single',   1,   1, q{}],
		solitary => ['solitary', 1,   1, q{}],
		solo     => ['solo',     1,   1, q{}],
		unique   => ['unique',   1,   1, q{}],
		duet     => ['duet',     1,   1, q{}],
		duo      => ['duo',      1,   1, q{}],
		partners => ['partners', 2,   2, q{}],
		plane    => ['plane',    2,   2, q{}],
		pair     => ['pair',     2,   2, q{}],
		pairs    => ['pairs',    2,   2, q{}],
		triad    => ['triad',    3,   3, q{}],
		trio     => ['trio',     3,   3, q{}],

		'mated individual' => ['mated individual', 2, 2, q{}],
		'mated pair'       => ['mated pair',       2, 2, q{}],
		'nesting pair'     => ['nesting pair',     2, 2, q{}],

		# barometz (b4 16)
		'serving druid masters' => [
			'solitary', 1, 1, 'serving druid masters',
			],

		# chained spirit (aon)
		'solitary plus up to 4 spirit anchors' => [
			'solitary', 1, 1, '0-4 spirit anchors',
			],

		# enisysian (aon)
		'with 1 veiled master' => [
			'solitary', 1, 1, '1 veiled master'
			],

		# bhuta (b3 41)
		'with a group of animals' => [
			'solitary', 1, 1, 'a group of animals',
			],

		# apocalypse horse (b6 12)
		'with associated horseman' => [
			'solitary', 1, 1, 'associated horseman',
			],

		# wild hunt archer (b6 279), wild hunt horse (b6 280), wild
		# hunt hound (b6 281), wild hunt monarch (b6 282), wild hunt
		# scout (b6 284)
		'wild hunt' => [q{wild hunt}, q{}, q{}, 'wild hunt'],

		# guardian spirit imp (aon)
		'with ward' => ['solitary', 1, 1, 'ward'],

		## guesses
		# xiao (b5 284)
		individuals => ['individuals', 1,  2, q{}],
		# lythirium (aon)
		pack        => ['pack',        3,  6, q{}],
		# nightgaunt (b4 203)
		colony      => ['colony',     13, 30, q{}],
		);

	my @results;

# TODO: what do I do with this?
# 'plus mounts (use statistics for ankylosaurus, pathfinder RPG bestiary 83)'

	my %fallback = (
		'band (with 3-12 lizardfolk)' => [
			'band', 1, 1, '3-12 lizardfolk',
			],
		'choir (3, 5, or 7)' => [
			'choir (3, 5, or 7)', 3, 7, q{},
			],
		'conflict (3-12, often with different attuned emotions)' => [
			'conflict (often with different attuned emotions)',
			3, 12, q{},
			],
		'coven (3 hags of any kind)' => [
			'coven', q{}, q{}, '3 hags of any kind',
			],
		'coven (3 hags of any type)' => [
			'coven', q{}, q{}, '3 hags of any kind',
			],
		'coven (three hags of any kind)' => [
			'coven', q{}, q{}, '3 hags of any kind',
			],
		'field (see below)' => [
			'field (see below)', 12, q{}, q{},
			],
		'group (all four apocalypse horses)' => [
			'group', 4, 4, 'all four apocalypse horses',
			],
		'pair (usually twins)' => [
			'pair (usually twins)', 2, 2, q{},
			],
		'solitary (none)' => [
			'solitary', 1, 1, q{},
			],
		'solitary (plus bonded creatures if any)' => [
			'solitary', 1, 1, 'bonded creatures if any',
			],
		'solitary (plus spawn)' => [
			'solitary', 1, 1, 'spawn',
			],
		'solitary (unique)' => [
			'unique', 1, 1, q{},
			],
		'tribe (with 13-60 lizardfolk)' => [
			'tribe', 1, 1, '13-60 lizardfolk',
			],
		);

	my $dp = CallDispatch->new;
	my $count = qr/(?<min>(?<max>\d+))/msx;
	my $floor = qr/(?<min>\d+)(?:[+]|(?:-\d+)?[ ]or[ ]more)/msx;
	my $range = qr/(?<min>\d+)-(?<max>\d+)/msx;
	my $roll  = qr/(?<min>\d+)d(?<die>\d+)/msx;
	my $trait = qr{
		(?<trait>(?:adult|swarm|disguised[ ]as[ ]a[ ]creature)s?)
	}msx;
	my $extra = qr{
		(?:and|including|plus|with|served[ ]by)
		[ ]
		(?<extra>.+)
	}msx;

	$dp->add(re2sub(qr/\A$count\z/msx));
	$dp->add(re2sub(qr/\A$count[ ]$trait\z/msx));
	$dp->add(re2sub(qr/\A$count[ ]$extra\z/msx));
	$dp->add(re2sub(qr/\A$count[ ]$trait[ ]$extra\z/msx));
	$dp->add(re2sub(qr/\A$floor\z/msx));
	$dp->add(re2sub(qr/\A$floor[ ]$trait\z/msx));
	$dp->add(re2sub(qr/\A$floor[ ]$extra\z/msx));
	$dp->add(re2sub(qr/\A$floor[ ]$trait[ ]$extra\z/msx));
	$dp->add(re2sub(qr/\A$range\z/msx));
	$dp->add(re2sub(qr/\A$range[ ]$trait\z/msx));
	$dp->add(re2sub(qr/\A$range[ ]$extra\z/msx));
	$dp->add(re2sub(qr/\A$range[ ]$trait[ ]$extra\z/msx));
	$dp->add(re2sub(qr/\A$roll\z/msx));
	$dp->add(re2sub(qr/\A$roll[ ]$extra\z/msx));

	for (@orgs) {
		my ($name, $desc) = @{$ARG};

		$desc =~ s/\A[(](.+)[)]\z/$1/msx;

		if ($desc eq q{}) {
			if (not exists $names{$name}) {
				croak "Unknown organization '$name'";
			}

			push @results, $names{$name};
			next;
		}

		my $org = "$name ($desc)";
		my @descs;

		for ($dp->apply($desc)) {
			if (defined $ARG) {
				push @descs, $ARG;
			}
		}

		if (@descs > 1) {
			croak "Multiple parsers match organization '$org'";
		}

		if (not @descs) {
			if (exists $fallback{$org}) {
				push @results, $fallback{$org};
				next;
			}

			#carp "Found complex organization '$org'";
			push @results, [$name, q{}, q{}, $desc];
			next;
		}

		my %desc = %{$descs[0]};

		if (exists $desc{die}) {
			$desc{max} = $desc{min} * $desc{die};
		}

		if (exists $desc{trait}) {
			$name = "$name ($desc{trait})";
		}

		my @maps = qw{min max extra};
		my @desc;

		for (0 .. $#maps) {
			my $key = $maps[$ARG];
			$desc[$ARG] = exists $desc{$key}? $desc{$key} : q{};
		}

		push @results, [$name, @desc];
	}

	return @results;
}

our $num;

sub fixorganization {
	my ($creature) = @ARG;
	my $name = $creature->{name};
	my @orgs = [q{}, q{}, q{}, q{}];

	if (exists $creature->{organization}) {
		@orgs = @{$creature->{organization}};
	}

	$num = defined $num? $num : 0;

	for (@orgs) {
		my ($org, $min, $max, $extra) = @{$ARG};

		if ($min ne q{}) {
			next;
		}

		if ($extra ne q{}) {
			($min, $max, $extra) = getselffromextra($name, $extra);
		}

		STDERR->printf("% 3u: %-40s %-18s %3s %3s %s\n", ++$num,
		               "$name:", $org, $min, $max, $extra);
	}

	return;
}

sub getselffromextra {
	my ($name, $extra) = @ARG;
	my @skip = (
		qr/forsaken[ ]arbalesters,[ ]defenders,[ ]and[ ]foot[ ]soldiers/msx,
		qr/witchfires[ ]and[ ]hags[ ]--[ ]see[ ]below/msx,
		);

	if (any { $extra =~ $ARG } @skip) {
		return q{}, q{}, $extra;
	}

	if ($extra eq 'wild hunt') {
		my %hunt = (
			'wild hunt monarch' => 1,
			'wild hunt scout'   => 1,
			'wild hunt archer'  => 3,
			'wild hunt horse'   => 3,
			'wild hunt hound'   => 4,
			);

		if (not exists $hunt{$name}) {
			croak "Creature '$name' doesn't belong to wild hunt";
		}

		my $whextra;

		for (sort { $hunt{$a} <=> $hunt{$b} } keys %hunt) {
			if ($hunt{$ARG} eq $name) {
				next;
			}

			my $tmp = $ARG;

			if ($hunt{$tmp} > 1) {
				$tmp .= 's';
			}

			if (defined $whextra) {
				$whextra = "$whextra, $hunt{$ARG} $tmp";
			} else {
				$whextra = "$hunt{$ARG} $tmp";
			}
		}

		return $hunt{$name}, $hunt{$name}, $whextra;
	}

	my @names = $name;

	if ($name =~ /\A(.+[ ]devil)[ ][(]([^()]+)[)]\z/msx) {
		push @names, $1, $2;
	}

	for (@{[@names]}) {
		push @names, $ARG =~ s/([a-rt-xz])\z/$1s/rmsx;
		push @names, $ARG =~ s/s\z/ses/rmsx;
		push @names, $ARG =~ s/y\z/ies/rmsx;
	}

	my %aliases = (
		'angazhani (high girallon)' => [qw{angazhani}],
		'brain mole monarch'        => [qw{monarch}],
		'daughter of urgathoa'      => [qw{daughter}],
		'director robot'            => [qw{director}],
		'giant queen bee'           => [qw{queen}],
		'hand of the inheritor'     => ['the hand'],
		'kurshu the undying'        => [qw{herald}],
		'latten mechanism'          => [qw{herald}],
		'silverblood lycanthrope (human form)' => [
			'silverblood werewolves',
			],
		'silverblood werewolf (hybrid form)' => [
			'silverblood werewolves',
			],
		'thriae queen'        => [qw{queen}],
		'treerazer'           => [qw{treerazor}],
		'yellow musk creeper' => [qw{creeper}],
		);

	if (exists $aliases{$name}) {
		push @names, @{$aliases{$name}};
	}

	@names = uniqstr @names;

	my $dp = CallDispatch->new;
	my $countre = qr/(?<min>(?<max>\d+))/msx;
	my $rangere = qr/(?<min>\d+)-(?<max>\d+)/msx;
	my $extrare = qr/(?:,?[ ](?:and|plus|with)|,)[ ](?<extra>.+)/msx;
	my $namesre = join q{|}, map { quotemeta $ARG } @names;
	$namesre = qr/(?:$namesre)/msx;

	$dp->add(re2sub(qr/\A$countre[ ]$namesre\z/msx));
	$dp->add(re2sub(qr/\A$countre[ ]$namesre$extrare\z/msx));
	$dp->add(re2sub(qr/\A$rangere[ ]$namesre\z/msx));
	$dp->add(re2sub(qr/\A$rangere[ ]$namesre$extrare\z/msx));

	$dp->add(re2sub(qr/\A(?<extra>.+?)[ ]and[ ]$rangere[ ]$namesre\z/msx));
	$dp->add(re2sub(qr/\A(?<extra>.+?)[ ]plus[ ]$rangere\z/msx));
	$dp->add(re2sub(qr/\A(?<single>$namesre(?<!s))$extrare\z/msx));

	$dp->add(re2sub(qr{\A
		$rangere[ ]$namesre
		[ ]
		(?<extra>mounted[ ]on[ ].+)
	\z}msx));

	my $lextrare = qr/(?<lextra>.+?)/msx;
	my $rextrare = qr/(?<rextra>.+)/msx;

	$dp->add(re2sub(qr{\A
		$lextrare
		[ ]and[ ]
		$rangere[ ]$namesre
		[ ]plus[ ]
		$rextrare
	\z}msx));

	my @results;

	for ($dp->apply($extra)) {
		if (defined $ARG) {
			push @results, $ARG;
		}
	}

	if (@results > 1) {
		croak "Multiple parsers match organization '$extra'";
	}

	if (not @results) {
		return q{}, q{}, $extra;
	}

	my %self = %{$results[0]};
	my @maps = qw{min max extra};
	my @self;

	if (exists $self{lextra}) {
		$self{extra} = "$self{lextra}, plus $self{rextra}";
	}

	if (exists $self{single}) {
		$self{min} = 1;
		$self{max} = 1;
	}

	for (0 .. $#maps) {
		my $key = $maps[$ARG];
		$self[$ARG] = exists $self{$key}? $self{$key} : q{};
	}

	return @self;
}
