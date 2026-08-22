#!/usr/bin/env rakupp
# eye-report.raku — data/ in, static site out. No scripts, no chart libraries:
# the charts are SVG assembled here, so there is nothing on the page to rot.
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

# One line chart: x is the row index, labelled with dates; several series; and
# vertical dashed markers where the environment changed under the series.
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
    $ymin -= $span * 0.08;
    $ymax += $span * 0.08;
    my sub X($i) { $n == 1 ?? ($w + $padl - $padr) / 2 !! $padl + ($w - $padl - $padr) * $i / ($n - 1) }
    my sub Y($v) { $padt + ($h - $padt - $padb) * (1 - ($v - $ymin) / ($ymax - $ymin)) }
    my @svg;
    @svg.push: qq[<svg viewBox="0 0 $w $h" role="img" style="width:100%;max-width:{$w}px">];
    for ^5 -> $g {
        my $v = $ymin + ($ymax - $ymin) * $g / 4;
        my $y = sprintf('%.1f', Y($v));
        @svg.push: qq[<line x1="$padl" y1="$y" x2="{$w - $padr}" y2="$y" stroke="#e3e3de" stroke-width="1"/>];
        @svg.push: qq[<text x="{$padl - 6}" y="{$y + 3.5}" text-anchor="end" font-size="10" fill="#8a8a83">{sprintf('%.4g', $v)}{$unit}</text>];
    }
    my $step = ($n / 7).ceiling max 1;
    for ^$n -> $i {
        next unless $i %% $step || $i == $n - 1;
        @svg.push: qq[<text x="{sprintf('%.1f', X($i))}" y="{$h - 6}" text-anchor="middle" font-size="9" fill="#8a8a83">{@dates[$i].substr(2)}</text>];
    }
    for @marks -> $m {
        my $x = sprintf('%.1f', X($m<i>));
        @svg.push: qq[<line x1="$x" y1="$padt" x2="$x" y2="{$h - $padb}" stroke="#c9a227" stroke-width="1" stroke-dasharray="3,3"/>];
        @svg.push: qq[<title>{esc($m<text>)}</title>];
    }
    for @series -> %s {
        my @pts = (^$n).grep({ %s<values>[$_].defined })
                       .map({ sprintf('%.1f,%.1f', X($_), Y(%s<values>[$_])) });
        if @pts > 1 {
            @svg.push: qq[<polyline points="{@pts.join(' ')}" fill="none" stroke="{%s<color>}" stroke-width="2"/>];
        }
        for (^$n).grep({ %s<values>[$_].defined }) -> $i {
            @svg.push: qq[<circle cx="{sprintf('%.1f', X($i))}" cy="{sprintf('%.1f', Y(%s<values>[$i]))}" r="2.6" fill="{%s<color>}"><title>{@dates[$i]}: {sprintf('%.4g', %s<values>[$i])}$unit — {esc(%s<name>)}</title></circle>];
        }
    }
    @svg.push: '</svg>';
    my $legend = @series.map({ qq[<span class="key"><span class="swatch" style="background:{.<color>}"></span>{esc(.<name>)}</span>] }).join(' ');
    qq[<div class="chart">{@svg.join("\n")}<div class="legend">{$legend}</div></div>]
}

sub table(@head, @rows) {
    return '<p class="thin">nothing this week</p>' unless @rows;
    my $h = @head.map({ "<th>{esc($_)}</th>" }).join;
    my $b = @rows.map({ '<tr>' ~ .map({ "<td>{esc($_)}</td>" }).join ~ '</tr>' }).join("\n");
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

    # --- clusters + regressions --------------------------------------------
    my $clusters = do {
        my $cf = $d.add("weeks/{$date}-clusters.tsv");
        if $cf.e {
            my @cr = $cf.lines.skip(1).map({ .split("\t", 2) }).grep({ .[1] });
            table(<files signature>, @cr.head(20).map({ [.[0], .[1]] }));
        }
        else { '<p class="thin">nothing this week</p>' }
    };
    my @regress-files = do {
        my $rf = $d.add("weeks/{$date}-regressions.txt");
        $rf.e ?? $rf.lines.grep(*.chars) !! ()
    };
    my $regress-html = $regr
        ?? qq[<div class="alert"><strong>{$regr} regression{$regr == 1 ?? '' !! 's'} this week.</strong> ]
           ~ @regress-files.map({ "<code>{esc($_)}</code>" }).join(', ') ~ '</div>'
        !! '<p class="ok">No regressions this week.</p>';

    my $eco-latest = do {
        if @eco {
            my %r = @eco.tail;
            table(<new pass self-fail dep-fail timeout other upstream-broken ours>,
                  [[ %r<new_releases>, %r<pass>, %r<self_fail>, %r<dep_fail>,
                     %r<timeout>, %r<other>, %r<upstream_broken>, %r<ours> ],]);
        }
        else { '<p class="thin">no data yet</p>' }
    };

    # --- the page -----------------------------------------------------------
    my $html = qq:to/END/;
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Raku Eye — the weekly watch on fresh Raku code</title>
    <style>
      :root \{ color-scheme: light \}
      body \{ margin: 0 auto; max-width: 780px; padding: 24px 16px 60px;
             font: 15px/1.55 -apple-system, "Segoe UI", sans-serif;
             color: #26261f; background: #faf9f5 \}
      h1 \{ font-size: 34px; letter-spacing: -0.4px; margin: 0 0 2px \}
      h2 \{ font-size: 18px; margin: 34px 0 6px; border-bottom: 1px solid #e3e3de; padding-bottom: 4px \}
      .tagline \{ font-size: 18px; color: #45453d; margin: 0 0 12px \}
      .sub \{ color: #6c6c64; margin: 2px 0 18px \}
      .cards \{ display: flex; flex-wrap: wrap; gap: 10px; margin: 18px 0 \}
      .card \{ flex: 1 1 150px; background: #fff; border: 1px solid #e3e3de; border-radius: 8px; padding: 10px 14px \}
      .card .n \{ font-size: 22px; font-weight: 600 \}
      .card .l \{ font-size: 12px; color: #6c6c64 \}
      .chart \{ background: #fff; border: 1px solid #e3e3de; border-radius: 8px; padding: 10px \}
      .legend \{ font-size: 12px; color: #55554e; margin-top: 4px \}
      .key \{ margin-right: 12px \}
      .swatch \{ display: inline-block; width: 9px; height: 9px; border-radius: 2px; margin-right: 4px \}
      .scroll \{ overflow-x: auto \}
      table \{ border-collapse: collapse; font-size: 13px; width: 100% \}
      th, td \{ text-align: left; padding: 4px 10px 4px 0; border-bottom: 1px solid #eeeee8; white-space: nowrap \}
      td:last-child \{ white-space: normal \}
      .alert \{ background: #fbeaea; border: 1px solid #e5b8b8; border-radius: 8px; padding: 10px 14px \}
      .ok \{ color: #2a6f4e \}
      .thin \{ color: #8a8a83 \}
      code \{ font-size: 12px; background: #f1f0ea; padding: 1px 4px; border-radius: 4px \}
      a \{ color: #1d5b8c \}
      footer \{ margin-top: 40px; font-size: 12px; color: #8a8a83 \}
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

    $regress-html

    <h2>Weekly Challenge</h2>
    <p class="sub">New solutions since the last run, the open set re-run, and a rotating 10% of past passes.</p>
    $pwc-chart

    <h2>raku-corpus</h2>
    <p class="sub">1,800-odd curated programs against committed Rakudo reference outputs. This line should hold or climb; any dip names the file that broke.</p>
    $corpus-chart

    <h2>Benchmarks — Rakudo time ÷ rakupp time</h2>
    <p class="sub">Above 1× means rakupp is faster. Measured back-to-back on the same runner each week; dashed lines mark a Rakudo release or toolchain change. Ratios are the series — absolute times from shared CI hardware are stored in the ledger but not headlined.</p>
    <h3>interpreter</h3>
    $bench-interp
    <h3>native (--exe)</h3>
    $bench-native
    $bench-latest

    <h2>Ecosystem — this week's releases</h2>
    $eco-latest

    <h2>Things to improve — this week's mismatch clusters</h2>
    <p class="sub">Mechanically grouped by normalized error signature; ranked by files affected.</p>
    $clusters

    <footer>Raw data: <a href="https://github.com/ash/raku-eye/tree/main/data">data/</a> —
    append-only TSV ledgers and per-week detail. Method:
    <a href="https://github.com/ash/rakupp/blob/main/docs/dev/plans/RAKU-EYE-PLAN.md">RAKU-EYE-PLAN.md</a>.
    No AI anywhere in this pipeline: it measures, clusters, and reports; fixing happens elsewhere.</footer>
    </body></html>
    END

    $o.add('index.html').spurt($html);
    $o.add('latest.json').spurt($d.add('latest.json').e ?? $d.add('latest.json').slurp !! "{}\n");
    # Belt and braces beside the repo's Pages custom-domain setting: a deploy
    # that carried no CNAME has dropped a domain before.
    $o.add('CNAME').spurt("eye.raku.online\n");
    note "site: {$o.add('index.html')} ({$o.add('index.html').s} bytes)";
}
