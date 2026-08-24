#!/usr/bin/env rakupp
# eye-report.raku — data/ in, static site out. No chart libraries and nothing
# fetched at page load: every mark is SVG assembled here, so the page still
# reads with scripting off. One small inline script enhances the charts that
# are too crowded to read statically — a crosshair that names the numbers, and
# a legend that switches lines off — and it only ever touches what this file
# emitted.
#
#   eye-run.raku ledger calls this as:  eye-report.raku --data=DIR --out=DIR

sub rows(IO::Path $f) {
    return () unless $f.e;
    my @lines = $f.lines.grep({ .chars && !.starts-with('#') });
    return () if @lines < 2;
    my @head = @lines[0].split("\t");
    @lines.skip(1).map({
        my @v = .split("\t");
        my %r;
        %r{@head[$_]} = @v[$_] // '' for ^@head;
        %r
    }).List
}

sub esc(Str() $s) {
    $s.subst('&', '&amp;', :g).subst('<', '&lt;', :g).subst('>', '&gt;', :g)
}

sub clip(Str() $s, $n = 96) {
    $s.chars > $n ?? $s.substr(0, $n) ~ '…' !! $s
}

# A test failure quotes the file it happened in, which for an ecosystem sweep is
# a path inside a throwaway install directory — two segments of serial number
# (the pid-stamped root, then either `dist` or the unpacked `Name-version`)
# in front of the part a reader can actually look up.
sub tidy-path(Str() $s) {
    $s.subst(/ \S*? 'rakupp-install-' <-[/\s]>+ '/' <-[/\s]>+ '/' /, '', :g)
}

# One string field out of a JSON object line. The mismatch ledger quotes whole
# program outputs, so the escapes are real: a regex to the next '"' would stop
# inside the first quoted string a program printed.
sub jfield(Str $line, Str $key) {
    my $k = "\"$key\":\"";
    my $i = $line.index($k);
    return '' unless $i.defined;
    my $p = $i + $k.chars;
    my $out = '';
    while $p < $line.chars {
        my $c = $line.substr($p, 1);
        if $c eq '\\' {
            my $n = $line.substr($p + 1, 1);
            given $n {
                when 'n'  { $out ~= "\n" }
                when 't'  { $out ~= "\t" }
                when 'r'  { }
                when 'u'  { $out ~= chr(:16($line.substr($p + 2, 4))); $p += 4 }
                default   { $out ~= $n }
            }
            $p += 2;
        }
        elsif $c eq '"' { last }
        else { $out ~= $c; $p++ }
    }
    $out
}

sub jnum(Str $line, Str $key) {
    $line ~~ / '"' $key '":' ('-'? \d+) / ?? ~$0 !! ''
}

# The first line where two outputs part company — what a reader actually wants
# from "the output differs".
sub first-diff(Str $want, Str $got) {
    my @w = $want.lines;
    my @g = $got.lines;
    for ^(@w.elems max @g.elems) -> $i {
        my $a = @w[$i];
        my $b = @g[$i];
        next if $a.defined && $b.defined && $a eq $b;
        return %( :line($i + 1), :want($a // '(no more output)'), :got($b // '(no more output)') );
    }
    Nil
}

# Verdict codes are the harness's vocabulary, not the reader's.
sub verdict-word(Str() $v) {
    given $v {
        when 'MATCH'     { 'byte-identical' }
        when 'DIFF-OUT'  { 'output differs' }
        when 'DIFF-EXIT' { 'exit status differs' }
        when 'DIFF-BOTH' { 'output and exit status differ' }
        when 'TIMEOUT'   { 'timed out' }
        default          { $v.lc }
    }
}

# One line chart: x is the row index, labelled with dates; several series; and
# vertical dashed markers where the environment changed under the series.
#
# The markup carries its own geometry (data-padl/-padr/-w/-dates) so the
# crosshair can map a pointer back to a data index without re-deriving it, and
# each series is a <g class="s"> the legend can switch off. With scripting off
# the <title> children still answer a hover, one point at a time.
my $chart-n = 0;
sub chart(@dates, @series, :@marks = (), :$w = 680, :$h = 200, :$ymin is copy, :$ymax is copy, :$unit = '') {
    my $n = +@dates;
    return '<p class="thin">no data yet</p>' unless $n && @series;
    my ($padl, $padr, $padt, $padb) = 46, 10, 8, 22;
    my @all = @series.map({ .<values>.grep(*.defined) }).flat;
    return '<p class="thin">no data yet</p>' unless @all;
    $ymin //= @all.min;
    $ymax //= @all.max;
    if $ymax - $ymin < 1e-9 { $ymin -= 1; $ymax += 1 }
    my $span = $ymax - $ymin;
    my $floor = @all.min;
    $ymin -= $span * 0.08;
    $ymax += $span * 0.08;
    # ratios and counts do not go negative; the breathing room below the lowest
    # point should not invent an axis label that cannot happen
    $ymin = 0 if $ymin < 0 && $floor >= 0;
    my sub X($i) { $n == 1 ?? ($w + $padl - $padr) / 2 !! $padl + ($w - $padl - $padr) * $i / ($n - 1) }
    my sub Y($v) { $padt + ($h - $padt - $padb) * (1 - ($v - $ymin) / ($ymax - $ymin)) }
    my $id = 'c' ~ $chart-n++;
    my @svg;
    @svg.push: qq[<svg viewBox="0 0 $w $h" role="img" style="width:100%;max-width:{$w}px"]
             ~ qq[ data-padl="$padl" data-padr="$padr" data-w="$w" data-unit="{esc($unit)}"]
             ~ qq[ data-dates="{esc(@dates.join('|'))}">];
    # A flat integer series (1608 twice) rounds five gridlines to three distinct
    # labels; a repeated one is noise, so the line stays and the text goes.
    my $last-label = '';
    for ^5 -> $g {
        my $v = $ymin + ($ymax - $ymin) * $g / 4;
        my $y = sprintf('%.1f', Y($v));
        @svg.push: qq[<line x1="$padl" y1="$y" x2="{$w - $padr}" y2="$y" stroke="#e3e3de" stroke-width="1"/>];
        my $label = sprintf('%.4g', $v) ~ $unit;
        next if $label eq $last-label;
        $last-label = $label;
        @svg.push: qq[<text x="{$padl - 6}" y="{$y + 3.5}" text-anchor="end" font-size="10" fill="#8a8a83">{$label}</text>];
    }
    my $step = ($n / 7).ceiling max 1;
    for ^$n -> $i {
        next unless $i %% $step || $i == $n - 1;
        @svg.push: qq[<text x="{sprintf('%.1f', X($i))}" y="{$h - 6}" text-anchor="middle" font-size="9" fill="#8a8a83">{@dates[$i].substr(2)}</text>];
    }
    # A <title> belongs to its own element: as a bare child of <svg> it became
    # the tooltip for the entire chart instead of the marker it described.
    for @marks -> $m {
        my $x = sprintf('%.1f', X($m<i>));
        @svg.push: qq[<g class="mark" data-i="{$m<i>}" data-text="{esc($m<text>)}">]
                 ~ qq[<line x1="$x" y1="$padt" x2="$x" y2="{$h - $padb}" stroke="#c9a227" stroke-width="1" stroke-dasharray="3,3"/>]
                 ~ qq[<title>{esc($m<text>)}</title></g>];
    }
    @svg.push: qq[<line class="guide" x1="0" y1="$padt" x2="0" y2="{$h - $padb}" stroke="#26261f" stroke-width="1" opacity="0.28" style="display:none"/>];
    for @series -> %s {
        my @defined = (^$n).grep({ %s<values>[$_].defined });
        my @pts = @defined.map({ sprintf('%.1f,%.1f', X($_), Y(%s<values>[$_])) });
        @svg.push: qq[<g class="s" data-name="{esc(%s<name>)}" data-color="{%s<color>}">];
        if @pts > 1 {
            @svg.push: qq[<polyline points="{@pts.join(' ')}" fill="none" stroke="{%s<color>}" stroke-width="2"/>];
        }
        for @defined -> $i {
            @svg.push: qq[<circle data-i="$i" data-v="{sprintf('%.4g', %s<values>[$i])}" cx="{sprintf('%.1f', X($i))}" cy="{sprintf('%.1f', Y(%s<values>[$i]))}" r="2.6" fill="{%s<color>}"><title>{@dates[$i]}: {sprintf('%.4g', %s<values>[$i])}$unit — {esc(%s<name>)}</title></circle>];
        }
        @svg.push: '</g>';
    }
    # last, so it is the element the pointer actually lands on
    @svg.push: qq[<rect class="hit" x="$padl" y="$padt" width="{$w - $padl - $padr}" height="{$h - $padt - $padb}" fill="transparent"/>];
    @svg.push: '</svg>';
    my $legend = @series.map({
        qq[<button type="button" class="key" aria-pressed="true"><span class="swatch" style="background:{.<color>}"></span>{esc(.<name>)}</button>]
    }).join(' ');
    my $allnone = @series > 3
        ?? qq[<span class="acts"><button type="button" class="mini" data-act="all">all</button><button type="button" class="mini" data-act="none">none</button></span>]
        !! '';
    # {…} rather than $legend$allnone: `$allnone</div>` is a hash subscript
    qq[<div class="chart" id="$id">{@svg.join("\n")}<div class="legend">{$legend}{$allnone}</div></div>]
}

sub table(@head, @rows) {
    return '<p class="thin">nothing this week</p>' unless @rows;
    my $h = @head.map({ "<th>{esc($_)}</th>" }).join;
    my $b = @rows.map({ '<tr>' ~ .map({ "<td>{esc($_)}</td>" }).join ~ '</tr>' }).join("\n");
    qq[<div class="scroll"><table><thead><tr>{$h}</tr></thead><tbody>{$b}</tbody></table></div>]
}

# Same, but the cells are already HTML.
sub table-raw(@head, @rows) {
    return '' unless @rows;
    my $h = @head.map({ "<th>{esc($_)}</th>" }).join;
    my $b = @rows.map({ '<tr>' ~ .map({ "<td>{$_}</td>" }).join ~ '</tr>' }).join("\n");
    qq[<div class="scroll"><table><thead><tr>{$h}</tr></thead><tbody>{$b}</tbody></table></div>]
}

sub MAIN(Str :$data!, Str :$out!) {
    my $d = $data.IO;
    my $o = $out.IO;
    $o.mkdir unless $o.d;

    my @pwc    = rows($d.add('pwc-history.tsv'));
    my @corpus = rows($d.add('corpus-history.tsv'));
    my @eco    = rows($d.add('eco-history.tsv'));
    my @bench  = rows($d.add('bench-history.tsv'));

    my $date = @pwc ?? @pwc.tail<date> !! (@corpus ?? @corpus.tail<date> !! ~Date.today);
    my $prev-date = @corpus > 1 ?? @corpus[*-2]<date> !! (@pwc > 1 ?? @pwc[*-2]<date> !! '');
    my $commit = @pwc ?? @pwc.tail<rakupp_commit> !! '';

    # --- headline ----------------------------------------------------------
    my ($pct, $open, $regr) = ('–', '–', 0);
    if @pwc {
        my %r = @pwc.tail;
        # The standing figure: the whole counted ledger, not this week's
        # tested set (which is open-set-heavy by construction).
        my $c = %r<pass_total> + %r<open_total>;
        $pct = $c ?? sprintf('%.1f%%', 100 * %r<pass_total> / $c) !! '–';
        $open = %r<open_total>;
        $regr = %r<regressions>.Int + (@corpus ?? @corpus.tail<regressions>.Int !! 0);
    }
    my $corpus-line = @corpus
        ?? "{@corpus.tail<match>} / {@corpus.tail<eligible>}"
        !! '–';
    my $eco-line = @eco
        ?? "{@eco.tail<pass>} green of {@eco.tail<new_releases>} new"
        !! '–';

    # --- PWC chart: standing match % of the counted ledger ------------------
    my @pwc-dates = @pwc.map(*.<date>);
    my @pwc-pct = @pwc.map({
        my $c = .<pass_total> + .<open_total>;
        $c ?? 100 * .<pass_total> / $c !! Nil
    });
    my $pwc-chart = chart(@pwc-dates,
        [ %( :name('byte-identical, % of the counted ledger'), :color('#2a6f4e'), :values(@pwc-pct) ), ],
        :ymin(0), :ymax(100), :unit(''));

    # --- corpus chart -------------------------------------------------------
    my @cd = @corpus.map(*.<date>);
    my @cm = @corpus.map({ .<match>.Int });
    my @cmarks;
    for 1 ..^ @corpus -> $i {
        if @corpus[$i]<corpus_commit> ne @corpus[$i - 1]<corpus_commit> {
            @cmarks.push: %( :i($i), :text("corpus moved to {@corpus[$i]<corpus_commit>.substr(0, 8)}") );
        }
    }
    my $corpus-chart = chart(@cd,
        [ %( :name('programs matching the Rakudo reference'), :color('#1d5b8c'), :values(@cm) ), ],
        :marks(@cmarks));

    # --- bench charts: ratios vs rakudo ------------------------------------
    my %by-kernel;
    my @bdates;
    my %seen-date;
    for @bench -> %r {
        @bdates.push(%r<date>) unless %seen-date{%r<date>}++;
        %by-kernel{%r<kernel>}.push(%r);
    }
    my @bmarks;
    if @bench {
        my @per-date = @bdates.map(-> $dd { @bench.first({ .<date> eq $dd }) });
        for 1 ..^ @per-date -> $i {
            if @per-date[$i]<rakudo> ne @per-date[$i - 1]<rakudo> {
                @bmarks.push: %( :i($i), :text("Rakudo {@per-date[$i]<rakudo>}") );
            }
            elsif @per-date[$i]<cxx> ne @per-date[$i - 1]<cxx> {
                @bmarks.push: %( :i($i), :text('toolchain changed') );
            }
        }
    }
    my @palette = <#2a6f4e #1d5b8c #b3542e #6b4d9e #8c1d51 #4e6f2a #27889e #9e6b1d #555555 #c02f4b #3b3b8c>;
    my sub ratio-series(Str $num) {
        my @s;
        for %by-kernel.keys.sort.kv -> $i, $k {
            my %at;
            for @(%by-kernel{$k}) -> $row {
                %at{$row<date>} = $row;
            }
            my @vals = @bdates.map(-> $dd {
                my $r = %at{$dd};
                my $v = Nil;
                if $r.defined && $r{$num} && $r<rakudo_min> {
                    $v = $r<rakudo_min> / $r{$num};
                }
                $v
            });
            @s.push: %( :name($k), :color(@palette[$i % @palette]), :values(@vals.List) );
        }
        @s
    }
    my $bench-interp = chart(@bdates, ratio-series('interp_min'), :marks(@bmarks), :unit('×'));
    my $bench-native = chart(@bdates, ratio-series('native_min'), :marks(@bmarks), :unit('×'));
    my $bench-latest = do {
        if @bench {
            my $last = @bdates.tail;
            my @lr = @bench.grep({ .<date> eq $last });
            table(<kernel interp native rakudo speedup-interp speedup-native flags>,
                  @lr.map({ [ .<kernel>,
                              .<interp_min> ?? "{.<interp_min>}ms" !! '–',
                              .<native_min> ?? "{.<native_min>}ms" !! '–',
                              .<rakudo_min> ?? "{.<rakudo_min>}ms" !! '–',
                              (.<interp_min> && .<rakudo_min>) ?? sprintf('%.1f×', .<rakudo_min> / .<interp_min>) !! '–',
                              (.<native_min> && .<rakudo_min>) ?? sprintf('%.1f×', .<rakudo_min> / .<native_min>) !! '–',
                              .<flags> ] }));
        }
        else { '<p class="thin">no data yet</p>' }
    };

    # --- what moved since last week ----------------------------------------
    # A regression here is never merely a program that fails: it is one that
    # WAS byte-identical to the Rakudo reference and is not any more, which is
    # why the page can always name it and say what changed. A bare count is
    # not a measurement anybody can act on.
    my $club-url   = 'https://github.com/manwar/perlweeklychallenge-club/blob/master/';
    my $corpus-url = 'https://github.com/ash/raku-corpus/blob/main/';
    my $no-detail  = '<span class="thin">detail not captured for this run</span>';

    my @regress-rows;

    # PWC: the regression list names the files; the week's mismatch ledger
    # carries the two outputs that disagree.
    my @pwc-regress = do {
        my $rf = $d.add("weeks/{$date}-regressions.txt");
        $rf.e ?? $rf.lines.grep(*.chars) !! ()
    };
    my %pwc-detail;
    my $jf = $d.add("weeks/{$date}-pwc.jsonl");
    if $jf.e && @pwc-regress {
        for $jf.lines -> $line {
            my $f = jfield($line, 'file');
            %pwc-detail{$f} = $line if $f && @pwc-regress.first($f);
        }
    }
    for @pwc-regress -> $f {
        my $why = $no-detail;
        with %pwc-detail{$f} -> $line {
            my @bits;
            my $ed = jnum($line, 'rakudo_exit');
            my $ep = jnum($line, 'rakupp_exit');
            with first-diff(jfield($line, 'rakudo'), jfield($line, 'rakupp')) -> %fd {
                @bits.push: "line {%fd<line>} — Rakudo <code>{esc(clip(%fd<want>))}</code>, "
                          ~ "rakupp <code>{esc(clip(%fd<got>))}</code>";
            }
            @bits.push: "exit <code>{esc($ep)}</code>, Rakudo <code>{esc($ed)}</code>" if $ep ne $ed;
            $why = @bits.join('<br>') if @bits;
        }
        @regress-rows.push: [
            'Weekly Challenge',
            qq[<a href="{$club-url}{$f}"><code>{esc($f)}</code></a>],
            'byte-identical → differs',
            $why,
        ];
    }

    # raku-corpus: the run records both directions of every verdict move, and
    # for a regression the line where the outputs part.
    my @cchanges = rows($d.add("weeks/{$date}-corpus-changes.tsv"));
    for @cchanges.grep({ .<kind> eq 'regression' }) -> %c {
        my @bits;
        if %c<line> {
            @bits.push: "line {%c<line>} — reference <code>{esc(clip(%c<expected>))}</code>, "
                      ~ "rakupp <code>{esc(clip(%c<got>))}</code>";
        }
        if %c<exit> ne '' && %c<exit> ne %c<expected_exit> {
            @bits.push: "exit <code>{esc(%c<exit>)}</code>, reference <code>{esc(%c<expected_exit>)}</code>";
        }
        @bits.push: "stderr: <code>{esc(clip(%c<stderr>))}</code>" if %c<stderr>;
        @regress-rows.push: [
            'raku-corpus',
            qq[<a href="{$corpus-url}{%c<file>.subst(/^ './' /, '')}"><code>{esc(%c<file>)}</code></a>],
            "{verdict-word(%c<was>)} → {verdict-word(%c<now>)}",
            @bits ?? @bits.join('<br>') !! $no-detail,
        ];
    }
    my @fixed = @cchanges.grep({ .<kind> eq 'fix' });

    my $n-regr = +@regress-rows || $regr;
    my $regress-html = do {
        if $n-regr {
            qq[<div class="alert"><strong>{$n-regr} regression{$n-regr == 1 ?? '' !! 's'} this week.</strong> ]
            ~ 'A program that was byte-identical to the Rakudo reference '
            ~ ($prev-date ?? "on $prev-date" !! 'on the previous run')
            ~ ' and is not today.</div>'
            ~ table-raw(('where', 'program', 'last week → this week', 'what differs'), @regress-rows)
        }
        else {
            '<p class="ok">No regressions this week — nothing that matched the Rakudo reference last week stopped matching.</p>'
        }
    };
    my $fixed-html = @fixed
        ?? qq[<p class="fixed"><strong>Fixed since {$prev-date || 'the previous run'}:</strong> ]
           ~ @fixed.map({
                 qq[<a href="{$corpus-url}{.<file>.subst(/^ './' /, '')}"><code>{esc(.<file>)}</code></a>]
                 ~ qq[ <span class="thin">({verdict-word(.<was>)})</span>]
             }).join(', ')
           ~ qq[ — {+@fixed == 1 ?? 'it matches' !! 'they match'} the reference again.</p>]
        !! '';

    my $clusters = do {
        my $cf = $d.add("weeks/{$date}-clusters.tsv");
        if $cf.e {
            my @cr = $cf.lines.skip(1).map({ .split("\t", 2) }).grep({ .[1] });
            table(<files signature>, @cr.head(20).map({ [.[0], .[1]] }));
        }
        else { '<p class="thin">nothing this week</p>' }
    };

    my $eco-latest = do {
        if @eco {
            my %r = @eco.tail;
            table(<new pass self-fail dep-fail timeout other upstream-broken ours>,
                  [[ %r<new_releases>, %r<pass>, %r<self_fail>, %r<dep_fail>,
                     %r<timeout>, %r<other>, %r<upstream_broken>, %r<ours> ],]);
        }
        else { '<p class="thin">no data yet</p>' }
    };

    # Every column of that row is a term of art, and one of them — "ours" — is
    # the only number on the page that says whose bug it is. Spell them out.
    my @eco-legend =
        'new'             => 'distributions that appeared in the REA index since the previous run. This leg sweeps exactly that set: the ecosystem is measured as it is published, week by week, not re-swept whole.',
        'pass'            => 'installed under <code>rakupp test</code>, and the distribution&#8217;s own test suite came out green.',
        'self-fail'       => 'it installed, but its own suite fails.',
        'dep-fail'        => 'a dependency broke first, so the distribution itself never got as far as being tested. The dependency is named in the table below.',
        'timeout'         => 'still running after 180 seconds, and killed.',
        'other'           => 'it failed for a reason the classifier does not recognise; the raw log line is in the table below.',
        'upstream-broken' => 'of the failures rakupp could be answerable for, the ones <strong>Rakudo cannot install either</strong>. The run re-tries each of them with <code>zef install</code> under Rakudo: if that fails too, the distribution is broken on its own account and is out of scope here.',
        'ours'            => '&#8230;and the ones where <strong>Rakudo installs and tests it fine</strong>. These are rakupp&#8217;s to fix — the single actionable number in the row.';

    my $eco-legend-html = '<dl class="defs">'
        ~ @eco-legend.map({ "<dt>{esc(.key)}</dt><dd>{.value}</dd>" }).join
        ~ '</dl>'
        ~ '<p class="sub">The control runs over <code>self-fail</code>, <code>build-fail</code>, '
        ~ '<code>timeout</code> and <code>other</code> only — a <code>dep-fail</code> is charged to the '
        ~ 'dependency, and shows up under its own name in a later week.</p>';

    # The tally says seven are ours; it should also say which seven.
    my $eco-fails = do {
        my $ef = $d.add("weeks/{$date}-eco.tsv");
        my @fails = $ef.e ?? rows($ef).grep({ .<verdict> && .<verdict> ne 'pass' }) !! ();
        if @fails {
            table-raw(('distribution', 'verdict', 'first error'),
                @fails.map({
                    [ qq[<a href="https://raku.land/?q={.<name>}"><code>{esc(.<name>)}</code></a>],
                      esc(.<verdict>) ~ (.<detail> ?? qq[ <span class="thin">({esc(.<detail>)})</span>] !! ''),
                      .<first-error> ?? qq[<code>{esc(clip(tidy-path(.<first-error>), 150))}</code>] !! '<span class="thin">&#8212;</span>' ]
                }));
        }
        else { '' }
    };

    my $css = q:to/CSS/;
      :root { color-scheme: light }
      body { margin: 0 auto; max-width: 780px; padding: 24px 16px 60px;
             font: 15px/1.55 -apple-system, "Segoe UI", sans-serif;
             color: #26261f; background: #faf9f5 }
      h1 { font-size: 34px; letter-spacing: -0.4px; margin: 0 0 2px }
      h2 { font-size: 18px; margin: 34px 0 6px; border-bottom: 1px solid #e3e3de; padding-bottom: 4px }
      .tagline { font-size: 18px; color: #45453d; margin: 0 0 12px }
      .sub { color: #6c6c64; margin: 2px 0 18px }
      .cards { display: flex; flex-wrap: wrap; gap: 10px; margin: 18px 0 }
      .card { flex: 1 1 150px; background: #fff; border: 1px solid #e3e3de; border-radius: 8px; padding: 10px 14px }
      .card .n { font-size: 22px; font-weight: 600 }
      .card .l { font-size: 12px; color: #6c6c64 }
      .chart { background: #fff; border: 1px solid #e3e3de; border-radius: 8px; padding: 10px; position: relative }
      .legend { font-size: 12px; color: #55554e; margin-top: 4px }
      .swatch { display: inline-block; width: 9px; height: 9px; border-radius: 2px; margin-right: 4px }
      .scroll { overflow-x: auto }
      table { border-collapse: collapse; font-size: 13px; width: 100% }
      th, td { text-align: left; padding: 4px 10px 4px 0; border-bottom: 1px solid #eeeee8; white-space: nowrap }
      td:last-child { white-space: normal }
      .alert { background: #fbeaea; border: 1px solid #e5b8b8; border-radius: 8px; padding: 10px 14px;
               margin-bottom: 12px }
      .ok { color: #2a6f4e }
      .fixed { font-size: 14px; color: #45453d; margin-top: 12px }
      .thin { color: #8a8a83 }
      code { font-size: 12px; background: #f1f0ea; padding: 1px 4px; border-radius: 4px }
      a { color: #1d5b8c }
      footer { margin-top: 40px; font-size: 12px; color: #8a8a83 }

      /* the legend doubles as a switchboard once the script is in */
      .key { font: inherit; color: inherit; background: none; border: 0; padding: 0;
             margin: 0 12px 2px 0; cursor: default }
      .js .key { cursor: pointer }
      .js .key:hover { color: #26261f }
      .key.off { color: #b4b4ac; text-decoration: line-through }
      .key.off .swatch { background: #d8d8d0 !important } /* beats the inline colour */
      .acts { display: none; white-space: nowrap }
      .js .acts { display: inline }
      .mini { font: inherit; font-size: 11px; color: #6c6c64; background: #f1f0ea;
              border: 1px solid #e3e3de; border-radius: 4px; padding: 0 6px; margin-left: 4px;
              cursor: pointer }
      .mini:hover { background: #e8e7df }
      g.s.off { display: none }

      /* the crosshair panel */
      .tip { position: absolute; top: 10px; pointer-events: none; display: none; z-index: 2;
             background: #fffdf7; border: 1px solid #d8d8d0; border-radius: 6px;
             box-shadow: 0 1px 6px rgba(38,38,31,0.12); padding: 6px 8px;
             font-size: 12px; line-height: 1.5; min-width: 150px; max-width: 330px }
      .tip-d { font-weight: 600; margin-bottom: 2px }
      .tip-d em { font-weight: 400; font-style: normal; color: #9a7d1f }
      .tip-r { display: flex; gap: 6px; align-items: baseline; white-space: nowrap }
      .tip-r .n { color: #55554e; overflow: hidden; text-overflow: ellipsis; max-width: 250px }
      .tip-r .v { margin-left: auto; font-variant-numeric: tabular-nums }
      .defs { display: grid; grid-template-columns: max-content 1fr; gap: 3px 14px;
              margin: 12px 0 4px; font-size: 13px }
      .defs dt { font-weight: 600; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                 font-size: 12px; color: #45453d; white-space: nowrap }
      .defs dd { margin: 0; color: #55554e }
      @media (max-width: 520px) { .defs { grid-template-columns: 1fr; gap: 0 }
                                  .defs dd { margin: 0 0 8px } }
      .hint { font-size: 12px; color: #8a8a83; margin: 0 0 8px; display: none }
      .js .hint { display: block }
    CSS

    # Progressive enhancement only: the script reads the geometry and the
    # values out of the SVG this file just wrote, and adds nothing the page
    # cannot lose. The native <title> tooltips go on init — with the panel up
    # they would fight it — which also means they are still there when the
    # script is not.
    my $js = q:to/JS/;
    (function () {
      document.documentElement.className += ' js';
      var charts = document.querySelectorAll('.chart');
      for (var c = 0; c < charts.length; c++) init(charts[c]);

      function init(chart) {
        var svg = chart.querySelector('svg');
        if (!svg) return;
        var groups = svg.querySelectorAll('g.s');
        var keys = chart.querySelectorAll('.key');
        if (!groups.length || !keys.length) return;

        var dates = (svg.getAttribute('data-dates') || '').split('|');
        var unit = svg.getAttribute('data-unit') || '';
        var padl = +svg.getAttribute('data-padl');
        var padr = +svg.getAttribute('data-padr');
        var vbw = +svg.getAttribute('data-w');
        var n = dates.length;

        var marks = {};
        var mnodes = svg.querySelectorAll('g.mark');
        for (var m = 0; m < mnodes.length; m++) {
          marks[mnodes[m].getAttribute('data-i')] = mnodes[m].getAttribute('data-text');
        }

        var titles = svg.querySelectorAll('title');
        for (var t = titles.length - 1; t >= 0; t--) titles[t].parentNode.removeChild(titles[t]);

        var guide = svg.querySelector('.guide');
        var hit = svg.querySelector('.hit');
        var tip = document.createElement('div');
        tip.className = 'tip';
        chart.appendChild(tip);
        var shown = -1;

        function isOff(g) { return g.getAttribute('class').indexOf('off') >= 0; }

        function setOn(key, g, on) {
          g.setAttribute('class', on ? 's' : 's off');
          key.className = on ? 'key' : 'key off';
          key.setAttribute('aria-pressed', on ? 'true' : 'false');
        }

        for (var k = 0; k < keys.length; k++) {
          (function (key, g) {
            key.addEventListener('click', function () {
              setOn(key, g, isOff(g));
              if (shown >= 0) show(shown);
            });
          })(keys[k], groups[k]);
        }
        var acts = chart.querySelectorAll('.mini');
        for (var a = 0; a < acts.length; a++) {
          (function (btn) {
            btn.addEventListener('click', function () {
              var on = btn.getAttribute('data-act') === 'all';
              for (var i = 0; i < groups.length; i++) setOn(keys[i], groups[i], on);
              if (shown >= 0) show(shown);
            });
          })(acts[a]);
        }

        function xOf(i) {
          return n === 1 ? (vbw + padl - padr) / 2 : padl + (vbw - padl - padr) * i / (n - 1);
        }

        function show(i) {
          shown = i;
          guide.setAttribute('x1', xOf(i));
          guide.setAttribute('x2', xOf(i));
          guide.style.display = '';

          var rows = [];
          for (var s = 0; s < groups.length; s++) {
            var live = !isOff(groups[s]);
            var dots = groups[s].querySelectorAll('circle');
            for (var q = 0; q < dots.length; q++) {
              var here = +dots[q].getAttribute('data-i') === i;
              dots[q].setAttribute('r', here && live ? '4.5' : '2.6');
            }
            if (!live) continue;
            var dot = groups[s].querySelector('circle[data-i="' + i + '"]');
            rows.push({
              name: groups[s].getAttribute('data-name'),
              color: groups[s].getAttribute('data-color'),
              v: dot ? dot.getAttribute('data-v') : null
            });
          }
          // biggest first: on a sixteen-kernel chart the ranking IS the reading
          rows.sort(function (a, b) {
            if (a.v === null) return 1;
            if (b.v === null) return -1;
            return parseFloat(b.v) - parseFloat(a.v);
          });

          var html = '<div class="tip-d">' + dates[i] +
                     (marks[i] ? ' <em>' + marks[i] + '</em>' : '') + '</div>';
          for (var r = 0; r < rows.length; r++) {
            html += '<div class="tip-r"><span class="swatch" style="background:' + rows[r].color +
                    '"></span><span class="n">' + rows[r].name + '</span><span class="v">' +
                    (rows[r].v === null ? '–' : rows[r].v + unit) + '</span></div>';
          }
          tip.innerHTML = html;
          tip.style.display = 'block';

          // the panel sits on whichever side of the crosshair has room for it
          var box = chart.getBoundingClientRect();
          var sbox = svg.getBoundingClientRect();
          var px = sbox.left - box.left + xOf(i) * sbox.width / vbw;
          var left = px + 12;
          if (left + tip.offsetWidth > box.width - 6) left = px - 12 - tip.offsetWidth;
          if (left < 6) left = 6;
          tip.style.left = left + 'px';
        }

        function hide() {
          shown = -1;
          tip.style.display = 'none';
          guide.style.display = 'none';
          var dots = svg.querySelectorAll('circle');
          for (var q = 0; q < dots.length; q++) dots[q].setAttribute('r', '2.6');
        }

        function at(ev) {
          if (n === 1) return 0;
          var r = svg.getBoundingClientRect();
          var x = (ev.clientX - r.left) * vbw / r.width;
          var i = Math.round((x - padl) / ((vbw - padl - padr) / (n - 1)));
          return Math.max(0, Math.min(n - 1, i));
        }

        hit.addEventListener('pointermove', function (ev) { show(at(ev)); });
        hit.addEventListener('pointerdown', function (ev) { show(at(ev)); });
        svg.addEventListener('pointerleave', hide);
      }
    })();
    JS

    # --- the page -----------------------------------------------------------
    my $html = qq:to/END/;
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Raku Eye — the weekly watch on fresh Raku code</title>
    <style>
    $css
    </style></head><body>
    <h1>Raku Eye</h1>
    <p class="tagline">The weekly watch on fresh Raku code.</p>
    <p class="sub">Every Monday, unattended, <a href="https://github.com/ash/rakupp">Raku++</a> is measured
    against what the Raku world published that week — Weekly Challenge solutions, new ecosystem
    releases, and the <a href="https://github.com/ash/raku-corpus">raku-corpus</a> golden battery —
    with Rakudo as both control and speed reference.
    Updated $date at rakupp <code>{$commit.substr(0, 9)}</code>.</p>

    <div class="cards">
      <div class="card"><div class="n">{$pct}</div><div class="l">Weekly Challenge — byte-identical of counted</div></div>
      <div class="card"><div class="n">{$corpus-line}</div><div class="l">raku-corpus programs matching reference</div></div>
      <div class="card"><div class="n">{$open}</div><div class="l">standing PWC mismatches (the open set)</div></div>
      <div class="card"><div class="n">{$eco-line}</div><div class="l">fresh ecosystem releases</div></div>
    </div>

    <h2>What moved this week</h2>
    $regress-html
    $fixed-html

    <h2>Weekly Challenge</h2>
    <p class="sub">New solutions since the last run, the open set re-run, and a rotating 10% of past passes.</p>
    <p class="hint">Hover a chart for that week's numbers; click a name in the legend to switch its line off.</p>
    $pwc-chart

    <h2>raku-corpus</h2>
    <p class="sub">1,800-odd curated programs against committed Rakudo reference outputs. This line should hold or climb; any dip names the file that broke, above.</p>
    $corpus-chart

    <h2>Benchmarks — Rakudo time ÷ rakupp time</h2>
    <p class="sub">Above 1× means rakupp is faster. Measured back-to-back on the same runner each week; dashed lines mark a Rakudo release or toolchain change. Ratios are the series — absolute times from shared CI hardware are stored in the ledger but not headlined.</p>
    <h3>interpreter</h3>
    $bench-interp
    <h3>native (--exe)</h3>
    $bench-native
    $bench-latest

    <h2>Ecosystem — this week's releases</h2>
    <p class="sub">Every distribution the ecosystem published since the last run, installed and run against its own test suite by <code>rakupp test</code> — with Rakudo as the control for anything that failed.</p>
    $eco-latest
    $eco-legend-html
    $eco-fails

    <h2>Things to improve — this week's mismatch clusters</h2>
    <p class="sub">Mechanically grouped by normalized error signature; ranked by files affected.</p>
    $clusters

    <footer>Raw data: <a href="https://github.com/ash/raku-eye/tree/main/data">data/</a> —
    append-only TSV ledgers and per-week detail. Method:
    <a href="https://github.com/ash/rakupp/blob/main/docs/dev/plans/RAKU-EYE-PLAN.md">RAKU-EYE-PLAN.md</a>.
    No AI anywhere in this pipeline: it measures, clusters, and reports; fixing happens elsewhere.</footer>
    <script>
    $js
    </script>
    </body></html>
    END

    $o.add('index.html').spurt($html);
    $o.add('latest.json').spurt($d.add('latest.json').e ?? $d.add('latest.json').slurp !! "{}\n");
    # Belt and braces beside the repo's Pages custom-domain setting: a deploy
    # that carried no CNAME has dropped a domain before.
    $o.add('CNAME').spurt("eye.raku.online\n");
    note "site: {$o.add('index.html')} ({$o.add('index.html').s} bytes)";
}
