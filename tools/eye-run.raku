#!/usr/bin/env rakupp
# eye-run.raku — the raku-eye driver: one subcommand per phase of the weekly run.
#
#   eye-run.raku fetch    everything that needs the network: the challenge-club
#                         partial clone, today's REA index, the corpus clone
#   eye-run.raku measure  the three network-free legs: PWC delta sweep,
#                         raku-corpus golden battery, benchmarks
#   eye-run.raku eco      the ecosystem leg (rakupp test fetches dependencies,
#                         so this one needs the network — run it token-free)
#   eye-run.raku ledger   append the history rows, write latest.json, build the
#                         site
#
# Runs under the rakupp binary built minutes earlier in the same workflow; the
# tools are also tests. Every phase is restartable: state only moves in
# `ledger`, and only after the artifacts it summarizes exist.
#
# Paths (all overridable): the repo root is the parent of tools/.
#   --work=DIR     scratch for this run          (default ROOT/work)
#   --data=DIR     append-only ledgers           (default ROOT/data)
#   --state=DIR    what next week starts from    (default ROOT/state)
#   --rakupp-repo=DIR  the rakupp checkout       (default ROOT/rakupp)
#   --club=DIR     challenge-club clone          (default WORK/club)
#   --corpus=DIR   raku-corpus clone             (default WORK/corpus)

my $ROOT = $*PROGRAM.absolute.IO.parent.parent;

sub cfg(%o) {
    my %c;
    %c<work>   = (%o<work>   // $ROOT.add('work')).IO;
    %c<data>   = (%o<data>   // $ROOT.add('data')).IO;
    %c<state>  = (%o<state>  // $ROOT.add('state')).IO;
    %c<rakupp-repo> = (%o<rakupp-repo> // $ROOT.add('rakupp')).IO;
    %c<club>   = (%o<club>   // %c<work>.add('club')).IO;
    %c<corpus> = (%o<corpus> // %c<work>.add('corpus')).IO;
    %c<rakupp> = %o<rakupp> // $*EXECUTABLE.absolute;
    %c<rakudo> = %o<rakudo> // 'raku';
    %c<work>.mkdir unless %c<work>.d;
    %c
}

# Run a command, streaming nothing; die loudly on failure unless :ok.
sub sh(*@cmd, :$ok = False, :$cwd = $*CWD) {
    note "  \$ {@cmd.join(' ')}";
    my $p = run(|@cmd, :cwd($cwd));
    if $p.exitcode != 0 && !$ok {
        die "command failed ({$p.exitcode}): {@cmd.join(' ')}";
    }
    $p.exitcode
}

# Run a command and capture stdout (stderr passes through to the log).
sub capture(*@cmd, :$cwd = $*CWD) {
    my $p = run(|@cmd, :out, :cwd($cwd));
    my $out = $p.out.slurp(:close);
    ($out, $p.exitcode)
}

sub git-head(IO::Path $repo) {
    my ($out, $ec) = capture('git', '-C', ~$repo, 'rev-parse', 'HEAD');
    $ec == 0 ?? $out.trim !! ''
}

sub jstr(Str $s) {
    '"' ~ $s.subst('\\', '\\\\', :g).subst('"', '\\"', :g)
            .subst("\n", '\\n', :g).subst("\t", '\\t', :g).subst("\r", '', :g) ~ '"'
}

# Append one TSV row, writing the header first if the file is new.
# One TSV cell: no tabs, no newlines, and bounded — these carry program output.
sub cell($v, $max = 200) {
    my $s = (~($v // '')).subst(/\t/, ' ', :g).subst(/\n/, ' ', :g).trim;
    $s.chars > $max ?? $s.substr(0, $max) ~ '…' !! $s
}

sub ledger-row(IO::Path $file, Str $header, Str $row) {
    my $new = !$file.e;
    my $fh = $file.open(:a);
    $fh.say: $header if $new;
    $fh.say: $row;
    $fh.close;
    note "  ledger: {$file.basename} += 1 row";
}

#----------------------------------------------------------------------------
sub do-fetch(%c) {

    # Challenge club: a partial clone with only the raku/ solution directories
    # checked out — the full tree is six years of two dozen languages.
    if %c<club>.add('.git').d {
        sh 'git', '-C', ~%c<club>, 'fetch', 'origin';
        sh 'git', '-C', ~%c<club>, 'merge', '--ff-only', 'FETCH_HEAD';
    }
    else {
        sh 'git', 'clone', '--filter=blob:none', '--no-checkout',
           'https://github.com/manwar/perlweeklychallenge-club', ~%c<club>;
        sh 'git', '-C', ~%c<club>, 'sparse-checkout', 'set', '--no-cone',
           'challenge-*/*/raku/';
        sh 'git', '-C', ~%c<club>, 'checkout', 'master';
    }
    note "club at {git-head(%c<club>)}";

    # Today's REA index, kept beside (not over) the previous snapshot.
    sh 'curl', '-sSL', '--retry', '3',
       'https://raw.githubusercontent.com/raku/REA/main/META.json',
       '-o', ~%c<work>.add('rea-today.json');
    note "REA index: {%c<work>.add('rea-today.json').s} bytes";

    # The corpus, shallow — it is small and we only need HEAD.
    if %c<corpus>.add('.git').d {
        sh 'git', '-C', ~%c<corpus>, 'pull', '--ff-only';
    }
    else {
        sh 'git', 'clone', '--depth=1', 'https://github.com/ash/raku-corpus', ~%c<corpus>;
    }
    note "corpus at {git-head(%c<corpus>)}";
}

#----------------------------------------------------------------------------
sub do-measure(%c) {
    my $work = %c<work>;

    # --- leg 1: PWC --------------------------------------------------------
    my $pwc-state = %c<state>.add('pwc-state.tsv');
    die "no {$pwc-state} — seed the state first" unless $pwc-state.e;
    my $last = '';
    for $pwc-state.lines -> $line {
        $last = ~$0 if $line.starts-with('#') && $line ~~ / 'commit=' (\S+) /;
        last unless $line.starts-with('#');
    }
    my $head = git-head(%c<club>);
    die "no club clone at {%c<club>} — run fetch first" unless $head;
    my $delta = $work.add('pwc-delta.txt');
    if $last && $last ne $head {
        my ($names, $) = capture('git', '-C', ~%c<club>, 'diff', '--name-only',
                                 '--no-renames', '--diff-filter=AM',
                                 "$last..$head", '--', 'challenge-*');
        my @new = $names.lines.grep({ .contains('/raku/') })
                              .grep({ .ends-with('.raku') || .ends-with('.p6') });
        $delta.spurt(@new.join("\n") ~ (@new ?? "\n" !! ''));
        note "PWC delta $last..$head: {+@new} files";
    }
    else {
        $delta.spurt('');
        note "PWC delta: none (state commit == HEAD)" if $last eq $head;
    }
    my $sweep-log = $work.add('pwc-sweep.log');
    my $p = run(%c<rakupp>, ~%c<rakupp-repo>.add('tools/pwc-sweep.raku'),
                "--files={$delta}", "--state={$pwc-state}",
                "--state-out={$work.add('pwc-state-new.tsv')}",
                '--sample=10', "--commit=$head",
                "--repo={%c<club>}", "--rakudo={%c<rakudo>}", "--rakupp={%c<rakupp>}",
                "--out={$work.add('pwc-mismatches.jsonl')}",
                "--tsv={$work.add('pwc-run.tsv')}",
                :out, :err);
    my $sweep-out = $p.out.slurp(:close);
    my $sweep-err = $p.err.slurp(:close);
    $sweep-log.spurt($sweep-out ~ "\n--- stderr ---\n" ~ $sweep-err);
    if $p.exitcode != 0 {
        # Print what went wrong rather than pointing at a file inside a
        # disposable VM. Exit 2 with a Usage block means rakupp's main is
        # older than the flags asked for — the tools live in the rakupp repo
        # and must be pushed there before the Eye can drive them.
        note "--- pwc-sweep stdout ---";
        note $sweep-out.lines.tail(20).join("\n");
        note "--- pwc-sweep stderr ---";
        note $sweep-err.lines.tail(20).join("\n");
        die "pwc-sweep failed (exit {$p.exitcode})";
    }
    note $sweep-out.lines.grep({ .starts-with('SUMMARY') || .starts-with('REGRESSION') }).join("\n");

    # --- leg 2: raku-corpus golden battery ---------------------------------
    my $status = %c<corpus>.add('run-status.tsv');
    die "no {$status} in the corpus clone" unless $status.e;
    my @eligible = $status.lines.map({ .split("\t") })
                          .grep({ .[0] eq 'OK' | 'NONZERO' })
                          .map({ .[4] });
    note "corpus: {+@eligible} eligible programs";
    my $list = $work.add('corpus-list.txt');
    $list.spurt(@eligible.join("\n") ~ "\n");
    my $results = $work.add('corpus-results');
    sh 'rm', '-rf', ~$results;
    my $ncpu = do {
        my ($n, $) = capture('getconf', '_NPROCESSORS_ONLN');
        ($n.trim || '4').Int
    };
    sh '/bin/sh', '-c',
       "RAKUPP='{%c<rakupp>}' RESULTS='$results' xargs -P $ncpu -n 1 " ~
       "'{%c<corpus>.add('harness/diff-rakupp.sh')}' < '$list'";
    my %ctally;
    my %cver;
    for run('find', ~$results, '-name', '*.verdict', :out).out.slurp(:close).lines -> $vf {
        my @f = $vf.IO.slurp.trim.split("\t");
        next unless @f >= 5;
        %ctally{@f[0]}++;
        %cver{@f[4]} = @f[0];
    }
    note "corpus verdicts: " ~ %ctally.keys.sort.map({ "$_={%ctally{$_}}" }).join(' ');
    # per-file verdicts + regressions against last week's corpus state
    my $corpus-state = %c<state>.add('corpus-state.tsv');
    my %cprev;
    if $corpus-state.e {
        for $corpus-state.lines.grep({ !.starts-with('#') }) -> $l {
            my ($v, $f) = $l.split("\t");
            %cprev{$f} = $v if $f;
        }
    }
    my @cregress = %cver.keys.grep({ (%cprev{$_} // '') eq 'MATCH' && %cver{$_} ne 'MATCH' }).sort;
    note "  CORPUS REGRESSION $_ ({%cver{$_}})" for @cregress;
    my $cfh = $work.add('corpus-run.tsv').open(:w);
    $cfh.say: "# corpus-commit={git-head(%c<corpus>)} date={Date.today}";
    $cfh.say: "{%cver{$_}}\t$_" for %cver.keys.sort;
    $cfh.close;
    $work.add('corpus-regressions.txt').spurt(@cregress.join("\n") ~ (@cregress ?? "\n" !! ''));

    # What moved since last week, both directions — and for a regression, WHY.
    # A count on the dashboard that no one can act on is not a measurement:
    # the harness leaves rakupp's own stdout and stderr beside the verdict for
    # every non-MATCH file, and the corpus carries the Rakudo reference, so the
    # first line where they part ways can be quoted on the page rather than
    # dug out of a CI log inside a VM that no longer exists.
    my @cchanges;
    for %cver.keys.sort -> $f {
        my $was = %cprev{$f} // '';
        my $now = %cver{$f};
        next if !$was || $was eq $now;
        next unless $was eq 'MATCH' || $now eq 'MATCH'; # DIFF-OUT -> DIFF-EXIT is not news
        my %d = kind => ($now eq 'MATCH' ?? 'fix' !! 'regression'),
                file => $f, was => $was, now => $now,
                exit => '', expected-exit => '', line => '', expected => '', got => '', stderr => '';
        if %d<kind> eq 'regression' {
            my $rel = $f.subst(/^ './' /, '');
            my $vf = $results.add("$rel.verdict");
            if $vf.e {
                my @v = $vf.slurp.trim.split("\t");
                %d<exit> = @v[1] // '';
                %d<expected-exit> = @v[2] // '';
            }
            my $got = $results.add("$rel.out");
            my $exp = %c<corpus>.add("expected/$rel.out");
            if $got.e && $exp.e {
                my @g = $got.lines;
                my @e = $exp.lines;
                for ^(@g.elems max @e.elems) -> $i {
                    my $a = @e[$i];
                    my $b = @g[$i];
                    next if $a.defined && $b.defined && $a eq $b;
                    %d<line>     = $i + 1;
                    %d<expected> = $a // '(no more output)';
                    %d<got>      = $b // '(no more output)';
                    last;
                }
            }
            my $errf = $results.add("$rel.err");
            %d<stderr> = ($errf.e ?? ($errf.lines.grep(*.chars).head // '') !! '');
        }
        @cchanges.push: %d;
    }
    note "corpus changes: {+@cchanges.grep({ .<kind> eq 'regression' })} regressed, "
       ~ "{+@cchanges.grep({ .<kind> eq 'fix' })} fixed";
    my $cch = $work.add('corpus-changes.tsv').open(:w);
    $cch.say: "kind\tfile\twas\tnow\texit\texpected_exit\tline\texpected\tgot\tstderr";
    for @cchanges -> %d {
        $cch.say: <kind file was now exit expected-exit line expected got stderr>
                  .map({ cell(%d{$_}) }).join("\t");
    }
    $cch.close;

    # --- leg 3: benchmarks -------------------------------------------------
    %*ENV<RAKUPP> = %c<rakupp>;
    %*ENV<RAKUDO> = %c<rakudo>;
    my $bp = run(%c<rakupp>, ~%c<rakupp-repo>.add('tools/run-bench.raku'),
                 "--tsv={$work.add('bench.tsv')}",
                 :out, :err);
    my $bout = $bp.out.slurp(:close);
    my $berr = $bp.err.slurp(:close);
    $work.add('bench.log').spurt($bout ~ "\n--- stderr ---\n" ~ $berr);
    note $bout.lines.tail(3).join("\n");
    if $bp.exitcode != 0 {
        note "bench exit {$bp.exitcode} (1 = an engine's output diverged; rows are still recorded, flagged)";
    }
    # A missing TSV is not a flagged row — it is no measurement at all, and it
    # must not pass quietly as "no bench data this week".
    unless $work.add('bench.tsv').e {
        note "--- run-bench stdout ---";
        note $bout.lines.tail(20).join("\n");
        note "--- run-bench stderr ---";
        note $berr.lines.tail(20).join("\n");
        die "run-bench produced no TSV (exit {$bp.exitcode})";
    }
}

#----------------------------------------------------------------------------
sub do-eco(%c) {
    my $work = %c<work>;

    # The delta: every dist string in today's index that the seen-set does
    # not contain. Line-wise field pulls, same as pick-fresh.raku.
    sub field($line, $key) {
        $line ~~ /'"' $key '":"' (<-["]>+) '"'/ ?? ~$0 !! ''
    }
    my $prev = %c<state>.add('rea-seen.txt');
    my $today = $work.add('rea-today.json');
    die "no $today — run fetch first" unless $today.e;
    my %seen;
    if $prev.e {
        %seen{$_} = True for $prev.lines.grep(*.chars);
    }
    my @fresh;
    for $today.lines -> $line {
        next unless $line.starts-with('{');
        my $dist = field($line, 'dist');
        next unless $dist;
        next if %seen{$dist};
        %seen{$dist} = True;
        my $name = $dist ~~ /^ (.+?) ':ver<'/ ?? ~$0 !! field($line, 'name');
        @fresh.push: { :name($name), :date(field($line, 'release-date')),
                       :ver(field($line, 'version')), :dist($dist) };
    }
    @fresh = @fresh.sort({ $^b<date> leg $^a<date> });
    # The updated seen-set (a union, one dist identity per line — all the
    # delta needs, and far lighter in git than an index snapshot; a yanked
    # dist also does not reappear as "new" if restored). ledger promotes it
    # into state/ once the sweep is recorded.
    $work.add('rea-seen-new.txt').spurt(%seen.keys.sort.join("\n") ~ "\n");
    note "eco delta: {+@fresh} new releases" ~ (!$prev.e ?? ' (no seen-set — first run records the baseline and sweeps nothing)' !! '');
    if !$prev.e {
        @fresh = ();
    }
    my $list = $work.add('eco-fresh.tsv');
    my $lfh = $list.open(:w);
    $lfh.say: "date\tname\tversion\tdist";
    $lfh.say: "{.<date>}\t{.<name>}\t{.<ver>}\t{.<dist>}" for @fresh;
    $lfh.close;

    if @fresh {
        my $results = $work.add('eco-results.tsv');
        # The options come BEFORE the list: args-to-capture stops recognising
        # --opt once a positional has been taken (Rakudo's rule, and rakupp
        # matches it), so a trailing --out= arrives as a literal string and
        # MAIN refuses the command line. The sweep spells its own usage the
        # same way. This cost the 2026-08-24 run its ecosystem leg.
        my $ec = sh %c<rakupp>, ~%c<rakupp-repo>.add('tools/eco-fresh/sweep-fresh.raku'),
           "--store={$work.add('eco-store')}", "--logs={$work.add('eco-logs')}",
           "--out=$results", '--timeout=180',
           "--rakupp={%c<rakupp>}", ~$list, :ok;
        # :ok tolerates a sweep that died partway — the rows it did write are
        # still worth recording, and the next run resumes from them — but not
        # one that produced no file at all, which is a broken invocation
        # rather than a broken distribution.
        die "the ecosystem sweep exited $ec without writing {$results.basename}" unless $results.e;
        note "the sweep exited $ec — recording the rows it managed to write" if $ec != 0;
        # Rakudo control for what failed on its own account: does zef manage to
        # install (and so test) it? A dist Rakudo also rejects is
        # upstream-broken and out of scope.
        my @rows = $results.lines.skip(1).map({ .split("\t") });
        my @suspect = @rows.grep({ .[3] eq 'self-fail' | 'build-fail' | 'other' | 'timeout' });
        my $ctrl = $work.add('eco-control.tsv').open(:w);
        $ctrl.say: "name\tcontrol";
        my $zec = do {
            my $r = 1;
            try {
                my $p = run('zef', '--version', :out, :err);
                $p.out.slurp(:close);
                $p.err.slurp(:close);
                $r = $p.exitcode;
            }
            $r
        };
        for @suspect -> @r {
            my $verdict;
            if $zec != 0 { $verdict = 'no-zef' }
            else {
                my $ec = sh '/usr/bin/perl', '-e',
                    'alarm shift; open(STDIN, "<", "/dev/null"); exec @ARGV or exit 127',
                    '300', 'zef', 'install', '--force-install', @r[0], :ok;
                $verdict = $ec == 0 ?? 'rakudo-pass' !! 'rakudo-fail';
            }
            $ctrl.say: "{@r[0]}\t$verdict";
            note "  control {@r[0]}: $verdict";
        }
        $ctrl.close;
    }
    else {
        $work.add('eco-results.tsv').spurt("name\tversion\treleased\tverdict\tdetail\tseconds\texit\tfirst-error\n");
        $work.add('eco-control.tsv').spurt("name\tcontrol\n");
    }
}

#----------------------------------------------------------------------------
sub do-ledger(%c, :$site) {
    my $work = %c<work>;
    my $date = ~Date.today;
    my $rakupp-commit = git-head(%c<rakupp-repo>);

    # --- PWC ---------------------------------------------------------------
    my %s;
    my @regress;
    for $work.add('pwc-sweep.log').lines -> $l {
        if $l.starts-with('SUMMARY ') {
            for $l.words.skip -> $kv {
                my ($k, $v) = $kv.split('=');
                %s{$k} = $v if $v.defined;
            }
        }
        @regress.push(~$0) if $l ~~ /^ 'REGRESSION ' (\S+) /;
    }
    @regress = @regress.unique;
    my $club-head = git-head(%c<club>);
    my $counted = (%s<match> // 0) + (%s<mismatch> // 0);
    ledger-row %c<data>.add('pwc-history.tsv'),
        "date\tclub_commit\trakupp_commit\ttested\tmatch\tmismatch\tregressions\tskip_rakudo\tskip_nondet\tgone\topen_total\tpass_total",
        ($date, $club-head, $rakupp-commit, %s<tested> // 0, %s<match> // 0,
         %s<mismatch> // 0, %s<regressions> // 0, %s<skip-rakudo-fails> // 0,
         %s<skip-nondeterministic> // 0, %s<gone> // 0,
         %s<open-total> // 0, %s<pass-total> // 0).join("\t");

    # promote the new state; archive the week's detail
    my $new-state = $work.add('pwc-state-new.tsv');
    if $new-state.e {
        %c<state>.add('pwc-state.tsv').spurt($new-state.slurp);
    }
    my $jsonl = $work.add('pwc-mismatches.jsonl');
    %c<data>.add("weeks/{$date}-pwc.jsonl").spurt($jsonl.e ?? $jsonl.slurp !! '');
    %c<data>.add("weeks/{$date}-regressions.txt").spurt(@regress.join("\n") ~ (@regress ?? "\n" !! ''));

    # clusters: normalized rakupp-stderr signature, else an output-shape class
    my %cluster;
    if $jsonl.e {
        for $jsonl.lines -> $line {
            my $sig;
            if $line ~~ /'"err":"' (<-["]>*) '"'/ && ~$0 {
                my $e = ~$0;
                $e = $e.subst(/ '/' \S+ '/challenge-' \S+ /, '<file>', :g);
                $e = $e.subst(/ \\? \' <-[']>* \\? \' /, "'…'", :g);
                $e = $e.subst(/ 'line ' \d+ /, 'line N', :g);
                $e = $e.subst(/ \d+ /, 'N', :g);
                $sig = $e.substr(0, 120);
            }
            elsif $line ~~ /'"rakupp":""'/ { $sig = '(no output from rakupp)' }
            else { $sig = '(output differs)' }
            %cluster{$sig}++;
        }
    }
    my $cl = %c<data>.add("weeks/{$date}-clusters.tsv").open(:w);
    $cl.say: "count\tsignature";
    $cl.say: "{%cluster{$_}}\t$_" for %cluster.keys.sort({ %cluster{$^b} <=> %cluster{$^a} || $^a leg $^b });
    $cl.close;

    # --- corpus ------------------------------------------------------------
    my %cver;
    my $corpus-commit = '';
    my $crun = $work.add('corpus-run.tsv');
    if $crun.e {
        for $crun.lines -> $l {
            if $l.starts-with('#') {
                $corpus-commit = ~$0 if $l ~~ / 'corpus-commit=' (\S+) /;
            }
            else {
                my ($v, $f) = $l.split("\t");
                %cver{$f} = $v if $f;
            }
        }
        my %t;
        %t{$_}++ for %cver.values;
        my @cregress = $work.add('corpus-regressions.txt').e
            ?? $work.add('corpus-regressions.txt').lines.grep(*.chars)
            !! ();
        ledger-row %c<data>.add('corpus-history.tsv'),
            "date\tcorpus_commit\trakupp_commit\teligible\tmatch\tdiff_out\tdiff_exit\tdiff_both\ttimeout\tregressions",
            ($date, $corpus-commit, $rakupp-commit, +%cver,
             %t<MATCH> // 0, %t<DIFF-OUT> // 0, %t<DIFF-EXIT> // 0,
             %t<DIFF-BOTH> // 0, %t<TIMEOUT> // 0, +@cregress).join("\t");
        %c<state>.add('corpus-state.tsv').spurt($crun.slurp);
        my $cch = $work.add('corpus-changes.tsv');
        %c<data>.add("weeks/{$date}-corpus-changes.tsv").spurt($cch.slurp) if $cch.e;
    }

    # --- eco ---------------------------------------------------------------
    my $eco = $work.add('eco-results.tsv');
    if $eco.e {
        my @rows = $eco.lines.skip(1).map({ .split("\t") }).grep({ .[3] });
        my %t;
        %t{.[3]}++ for @rows;
        my %ctrl;
        if $work.add('eco-control.tsv').e {
            for $work.add('eco-control.tsv').lines.skip(1) -> $l {
                my ($n, $v) = $l.split("\t");
                %ctrl{$v}++ if $v;
            }
        }
        ledger-row %c<data>.add('eco-history.tsv'),
            "date\trakupp_commit\tnew_releases\tpass\tself_fail\tbuild_fail\tdep_fail\tdep_build_fail\ttimeout\tunresolved\tother\tupstream_broken\tours",
            ($date, $rakupp-commit, +@rows, %t<pass> // 0, %t<self-fail> // 0,
             %t<build-fail> // 0, %t<dep-fail> // 0, %t<dep-build-fail> // 0,
             %t<timeout> // 0, %t<unresolved> // 0, %t<other> // 0,
             %ctrl<rakudo-fail> // 0, %ctrl<rakudo-pass> // 0).join("\t");
        %c<data>.add("weeks/{$date}-eco.tsv").spurt($eco.slurp);
        # the updated seen-set becomes the next run's baseline, only now
        if $work.add('rea-seen-new.txt').e {
            %c<state>.add('rea-seen.txt').spurt($work.add('rea-seen-new.txt').slurp);
        }
    }

    # --- bench -------------------------------------------------------------
    my $bench = $work.add('bench.tsv');
    if $bench.e {
        my %meta;
        my @brows;
        for $bench.lines -> $l {
            if $l.starts-with('# ') {
                my ($k, $v) = $l.substr(2).split('=', 2);
                %meta{$k} = $v // '';
            }
            elsif !$l.starts-with('kernel') && $l.chars {
                @brows.push: $l.split("\t");
            }
        }
        my $rv = %meta<rakudo_version> ~~ / ('v' \d+ '.' \S+?) '.'? $ / ?? ~$0 !! %meta<rakudo_version>;
        for @brows -> @r {
            ledger-row %c<data>.add('bench-history.tsv'),
                "date\trakupp_commit\trakudo\tcxx\tcpu\tkernel\tinterp_min\tinterp_med\tnative_min\tnative_med\trakudo_min\trakudo_med\tperl_min\tperl_med\tflags",
                ($date, $rakupp-commit, $rv, %meta<cxx> // '', %meta<cpu> // '',
                 |@r).join("\t");
        }
    }

    # --- latest.json + site ------------------------------------------------
    my $counted-n = $counted.Int;
    my $pct = $counted-n ?? sprintf('%.1f', 100 * (%s<match> // 0) / $counted-n) !! '';
    my %ctally;
    %ctally{$_}++ for %cver.values;
    my $latest = %c<data>.add('latest.json');
    $latest.spurt: '{'
        ~ '"date":' ~ jstr($date)
        ~ ',"rakupp_commit":' ~ jstr($rakupp-commit)
        ~ ',"pwc":{"tested":' ~ (%s<tested> // 0) ~ ',"match":' ~ (%s<match> // 0)
            ~ ',"mismatch":' ~ (%s<mismatch> // 0) ~ ',"regressions":' ~ (%s<regressions> // 0)
            ~ ',"open_total":' ~ (%s<open-total> // 0) ~ ',"pass_total":' ~ (%s<pass-total> // 0) ~ '}'
        ~ ',"corpus":{"eligible":' ~ (+%cver) ~ ',"match":' ~ (%ctally<MATCH> // 0) ~ '}'
        ~ '}' ~ "\n";
    note "latest.json written";

    my $site-dir = $site // ~$ROOT.add('site-build');
    sh %c<rakupp>, ~$ROOT.add('tools/eye-report.raku'),
       "--data={%c<data>}", "--out=$site-dir";
}

#----------------------------------------------------------------------------
sub MAIN(Str $phase,
         Str :$work, Str :$data, Str :$state, Str :$rakupp-repo,
         Str :$club, Str :$corpus, Str :$rakupp, Str :$rakudo, Str :$site) {
    my %c = cfg(%(:$work, :$data, :$state, :$rakupp-repo,
                  :$club, :$corpus, :$rakupp, :$rakudo));
    given $phase {
        when 'fetch'   { do-fetch(%c) }
        when 'measure' { do-measure(%c) }
        when 'eco'     { do-eco(%c) }
        when 'ledger'  { do-ledger(%c, :$site) }
        default        { note "eye-run: unknown phase '$phase' (fetch|measure|eco|ledger)"; exit 2 }
    }
}
