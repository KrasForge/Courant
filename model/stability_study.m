function stability_study(varargin)
% STABILITY_STUDY  CFL / Courant-number stability sweep (MATLAB / Octave).
%
% Sweeps gamma^2 around the theoretical 2D CFL boundary (gamma^2 = 0.5),
% runs a short undamped simulation for each value, and classifies each run
% as stable or divergent.  Produces:
%
%   model/outputs/cfl_sweep_envelope.png   log peak-amplitude vs. time
%   model/outputs/cfl_classification.png   stable/divergent bar chart
%   stdout                                 summary table + gamma2_max value
%
% Theory (README §1):
%   The explicit 2D scheme is stable iff  gamma^2 <= 1/2.
%   Crossing the boundary causes exponential divergence.
%
% Name/value options:
%   'plots'  (logical) write PNG plots  [default true; pass false for headless]
%   'outdir' (char)    output directory [default model/outputs/]

    % ---- Sweep configuration ----------------------------------------------
    SWEEP_GAMMA2 = [ ...
        0.10, 0.20, 0.30, 0.40, ...            % well inside stable region
        0.45, 0.48, 0.490, 0.499, ...          % approaching the boundary
        0.500, ...                             % theoretical CFL limit
        0.501, 0.510, 0.52, 0.55, 0.60, 0.70]; % unstable region
    CFL_LIMIT  = 0.5;       % 1/2 — theoretical 2D stability boundary

    C.NX        = 24;       % grid size; small for a fast sweep
    C.NY        = 24;
    C.FS        = 48000;    % Hz
    C.H         = 0.01;     % m, spatial step
    C.SIGMA     = 0.0;      % undamped — cleanest divergence signal
    C.DURATION  = 0.10;     % s  (100 ms per run)
    C.SAMPLE_MS = 0.5;      % amplitude sample interval (ms)
    C.DIV_THRESH = 1e6;     % classify divergent above this peak displacement

    P.plots = true;
    here = fileparts(mfilename('fullpath'));
    P.outdir = fullfile(here, 'outputs');
    P = parse_opts(P, varargin);
    if ~exist(P.outdir, 'dir'); mkdir(P.outdir); end

    fprintf('2D FDTD CFL stability sweep\n');
    fprintf('  Grid     : %dx%d   fs=%g Hz   h=%g m   sigma=%g\n', ...
            C.NX, C.NY, C.FS, C.H, C.SIGMA);
    fprintf('  Duration : %.0f ms per run\n', C.DURATION * 1e3);
    fprintf('  CFL limit: gamma^2 = %g  (gamma = %.4f)\n\n', ...
            CFL_LIMIT, sqrt(CFL_LIMIT));

    header = sprintf('%8s  %8s  %12s  %12s  %12s  div. time', ...
                     'gamma^2', 'gamma', 'status', 'peak@10ms', 'peak@end');
    fprintf('%s\n', header);
    fprintf('%s\n', repmat('-', 1, numel(header)));

    n = numel(SWEEP_GAMMA2);
    results = struct('g2', cell(1, n), 'times', [], 'env', [], 'div_ms', []);

    for i = 1:n
        g2 = SWEEP_GAMMA2(i);
        [times, env, div_ms] = run_one(g2, C);

        idx10 = find(times >= 10.0, 1, 'first');
        if isempty(idx10); idx10 = numel(env); end
        p10  = env(min(idx10, numel(env)));
        pend = env(end);
        if isempty(div_ms)
            status = 'stable';   div_str = '-';
        else
            status = 'DIVERGENT'; div_str = sprintf('%.1f ms', div_ms);
        end

        fprintf('%8.4f  %8.5f  %12s  %12.3e  %12.3e  %s\n', ...
                g2, sqrt(g2), status, p10, pend, div_str);

        results(i).g2 = g2;
        results(i).times = times;
        results(i).env = env;
        results(i).div_ms = div_ms;
    end

    % ---- Recommendation ---------------------------------------------------
    stable_g2 = [results(cellfun(@isempty, {results.div_ms})).g2];
    if isempty(stable_g2); empirical_max = 0.0; else; empirical_max = max(stable_g2); end
    % 10% margin below the empirical limit, rounded to 3 d.p. for clean
    % RTL coefficients.
    gamma2_max = round(empirical_max * 0.90 * 1000) / 1000;

    fprintf('\n%s\n', repmat('-', 1, 60));
    fprintf('Empirical stable maximum : gamma^2 = %.4f\n', empirical_max);
    fprintf('Recommended gamma2_max   : %.3f\n\n', gamma2_max);
    fprintf('Rationale:\n');
    fprintf('  The scheme diverges exponentially for gamma^2 > 0.5 (CFL limit).\n');
    fprintf('  The non-linear term (alpha*u^2, README §2) raises the effective\n');
    fprintf('  local gamma^2 above gamma0^2 on loud transients.  A 10%% margin\n');
    fprintf('  below the empirical limit gives gamma2_max = %.3f, leaving\n', gamma2_max);
    fprintf('  headroom of %.3f for the amplitude-dependent stiffening\n', CFL_LIMIT - gamma2_max);
    fprintf('  before the hard clamp engages.\n\n');

    if ~P.plots; return; end
    % Plotting is a secondary aid; if no graphics toolkit is available
    % (e.g. a bare headless install) skip it rather than failing the study.
    try
        fprintf('Writing plots:\n');
        save_envelope_plot(results, C, P.outdir);
        save_classification_plot(results, gamma2_max, CFL_LIMIT, P.outdir);
        fprintf('Done.\n');
    catch err
        fprintf('  Plotting unavailable (%s) - skipping plots.\n', err.message);
    end
end

% ===========================================================================
% Per-run simulation
% ===========================================================================

function [times_ms, envelope, div_ms] = run_one(gamma2, C)
    % Run one undamped simulation with the given gamma^2.
    % Returns sample times (ms), the peak |u|_inf envelope, and the
    % divergence time in ms (empty if the run stayed stable).
    c = sqrt(gamma2) * C.H * C.FS;
    mesh = Mesh2D(C.NX, C.NY, C.FS, C.H, c, C.SIGMA, 'fixed', false);
    mesh.strike(floor(C.NY/2), floor(C.NX/2), 2.0, 1.0);

    n_total    = round(C.DURATION * C.FS);
    samp_every = max(1, round(C.SAMPLE_MS * 1e-3 * C.FS));

    times_ms = [];
    envelope = [];
    div_ms   = [];

    for n = 1:n_total
        if mod(n - 1, samp_every) == 0
            peak = max(abs(mesh.u(:)));
            bad  = ~isfinite(peak) || peak > C.DIV_THRESH;
            times_ms(end+1) = (n - 1) / C.FS * 1e3; %#ok<AGROW>
            if isfinite(peak)
                envelope(end+1) = min(peak, C.DIV_THRESH * 10); %#ok<AGROW>
            else
                envelope(end+1) = C.DIV_THRESH * 10; %#ok<AGROW>
            end
            if bad
                div_ms = (n - 1) / C.FS * 1e3;
                break;
            end
        end
        mesh.step();
    end
end

% ===========================================================================
% Plots
% ===========================================================================

function save_envelope_plot(results, C, outdir)
    fig = figure('visible', 'off', 'position', [100 100 1100 600]);
    ax = axes(fig); hold(ax, 'on');

    for i = 1:numel(results)
        r = results(i);
        stable = isempty(r.div_ms);
        if stable
            col = [0.2 0.4 0.8]; ls = '-';  lw = 1.2;
        else
            col = [0.85 0.2 0.2]; ls = '--'; lw = 1.5;
        end
        semilogy(ax, r.times, max(r.env, 1e-6), ls, ...
                 'Color', col, 'LineWidth', lw, ...
                 'DisplayName', sprintf('gamma^2=%.3f', r.g2));
    end
    yline_compat(ax, C.DIV_THRESH);

    xlabel(ax, 'Time (ms)');
    ylabel(ax, 'Peak displacement  ||u||_\infty');
    title(ax, {'CFL sweep — peak displacement envelope', ...
               'solid = stable, dashed = divergent'});
    legend(ax, 'Location', 'northwest', 'FontSize', 7, 'NumColumns', 2);
    ylim(ax, [1e-5, C.DIV_THRESH * 50]);

    path = fullfile(outdir, 'cfl_sweep_envelope.png');
    print(fig, path, '-dpng', '-r150');
    close(fig);
    fprintf('  wrote %s\n', path);
end

function save_classification_plot(results, gamma2_max, cfl_limit, outdir)
    g2 = [results.g2];
    fig = figure('visible', 'off', 'position', [100 100 1200 350]);
    ax = axes(fig); hold(ax, 'on');

    for i = 1:numel(results)
        if isempty(results(i).div_ms)
            col = [0.27 0.51 0.71];   % steelblue (stable)
        else
            col = [1.0 0.39 0.28];    % tomato (divergent)
        end
        bar(ax, i, 1, 'FaceColor', col, 'EdgeColor', 'k', 'BarWidth', 0.9);
    end

    cfl_idx = find(g2 >= cfl_limit, 1, 'first');
    if isempty(cfl_idx); cfl_idx = numel(g2) + 1; end
    plot(ax, [cfl_idx-0.5 cfl_idx-0.5], [0 1.05], 'k--', 'LineWidth', 2);

    gmax_idx = find(g2 > gamma2_max, 1, 'first');
    if isempty(gmax_idx); gmax_idx = numel(g2) + 1; end
    plot(ax, [gmax_idx-0.5 gmax_idx-0.5], [0 1.05], ':', ...
         'Color', [0 0.5 0], 'LineWidth', 2);

    set(ax, 'XTick', 1:numel(g2), ...
            'XTickLabel', arrayfun(@(x) sprintf('%.3f', x), g2, ...
                                   'UniformOutput', false), ...
            'YTick', []);
    xtickangle(ax, 45);
    xlabel(ax, 'gamma^2');
    title(ax, sprintf(['CFL classification: stable (blue) / divergent (red)' ...
                       '   —   CFL=%.2f, gamma2\\_max=%.3f'], ...
                      cfl_limit, gamma2_max));
    xlim(ax, [0.5, numel(g2) + 0.5]);
    ylim(ax, [0, 1.1]);

    path = fullfile(outdir, 'cfl_classification.png');
    print(fig, path, '-dpng', '-r150');
    close(fig);
    fprintf('  wrote %s\n', path);
end

% ===========================================================================
% Small helpers
% ===========================================================================

function P = parse_opts(P, args)
    if mod(numel(args), 2) ~= 0
        error('stability_study:args', 'Options must be name/value pairs.');
    end
    for i = 1:2:numel(args)
        name = lower(args{i});
        switch name
            case 'plots';  P.plots  = logical(args{i+1});
            case 'outdir'; P.outdir = args{i+1};
            otherwise
                error('stability_study:args', 'Unknown option "%s".', args{i});
        end
    end
end

function yline_compat(ax, y)
    % yline() is not in older Octave; draw a horizontal reference line.
    xl = xlim(ax);
    if xl(2) <= xl(1); xl = [0 1]; end
    plot(ax, xl, [y y], 'k:', 'LineWidth', 0.8, ...
         'DisplayName', 'div. threshold (1e6)');
end
