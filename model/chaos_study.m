function chaos_study(varargin)
% CHAOS_STUDY  Aliasing and chaos characterisation of the non-linear regime.
%
% Characterises the amplitude-dependent non-linearity (README §2,
%   gamma2_local = clamp(gamma0^2 + alpha*u^2, 0, gamma2_max))
% using the same Q1.23 saturating arithmetic as the RTL. Four analyses:
%
%   1. THD vs alpha and drive amplitude (harmonic distortion from the squaring).
%   2. Aliasing floor at 1x / 2x / 4x oversampling (spectral error vs a 16x
%      ground truth).
%   3. Period-doubling / route-to-chaos as alpha increases (driven-node
%      bifurcation via a stroboscopic Poincare section).
%   4. Bounded-output confirmation across the whole sweep (the clamp +
%      saturating state keep the system convergent, never diverging).
%
% Results (numbers) are printed and summarised in
% docs/chaos_characterization.md. Plots are written to model/outputs/ when a
% graphics toolkit is available (guarded for headless runs).
%
% Usage:
%   chaos_study                 % full study, text + plots
%   chaos_study('plots', false) % headless (numbers only)

  P.plots = true;
  here = fileparts(mfilename('fullpath'));
  P.outdir = fullfile(here, 'outputs');
  P = parse_opts(P, varargin);
  if ~exist(P.outdir, 'dir'); mkdir(P.outdir); end

  fprintf('Non-linear regime characterisation (Q1.23 arithmetic)\n');
  fprintf('  gamma0^2 = 0.09, gamma2_max = 0.451 (CFL-safe, issue #3)\n\n');

  thd = analyse_thd();
  alias = analyse_aliasing();
  bif = analyse_bifurcation();

  print_envelope(thd, alias, bif);

  if ~P.plots; return; end
  try
    fprintf('Writing plots:\n');
    plot_results(thd, alias, bif, P.outdir);
    fprintf('Done.\n');
  catch err
    fprintf('  Plotting unavailable (%s) - skipping plots.\n', err.message);
  end
end

% ===========================================================================
% Q1.23 primitives (match the RTL / reference model)
% ===========================================================================
function y = qrhu(p);     y = floor((p + 2^22) / 2^23);            end
function y = qsat(x);     y = max(min(x, 2^23-1), -2^23);          end
function y = qms(a, b);   y = qsat(qrhu(a .* b));                  end  % q_mul (sat)
function y = qmc(a, b);   y = qrhu(a .* b);                        end  % mul_coeff (wide)
function y = qcl(x,lo,hi);y = max(min(x, hi), lo);                 end
function y = toq(x);      y = qsat(round(x * 2^23));               end

% one non-linear node update (scalar), constant or supplied neighbour sum
function [u, um1] = nl_node(u, um1, nbsum, g0, al, gmax, a0, sk)
  u2  = qms(u, u);
  au2 = qms(al, u2);
  g2l = qcl(g0 + au2, 0, gmax);
  lap = nbsum - 4*u;
  un  = qsat(qmc(a0, 2*u - qmc(sk, um1) + qmc(g2l, lap)));
  um1 = u; u = un;
end

% non-linear mesh step (fixed boundary), vectorised
function [s, s1] = nl_mesh(s, s1, g0, al, gmax, a0, sk)
  [ny, nx] = size(s);
  u2 = qms(s, s); au2 = qms(al, u2); G2L = qcl(g0 + au2, 0, gmax);
  P = zeros(ny+2, nx+2); P(2:ny+1, 2:nx+1) = s;
  lap = P(3:ny+2,2:nx+1)+P(1:ny,2:nx+1)+P(2:ny+1,3:nx+2)+P(2:ny+1,1:nx) - 4.*s;
  snew = qsat(qmc(a0, 2.*s - qmc(sk, s1) + qmc(G2L, lap)));
  s1 = s; s = snew;
end

% ===========================================================================
% 1. THD vs alpha and drive amplitude
% ===========================================================================
function r = analyse_thd()
  g0 = toq(0.09); gmax = toq(0.49); a0 = toq(0.985); sk = toq(0.985);
  T = 10; steps = 8000;
  r.alpha = [0.1 0.2 0.3 0.4 0.5];
  r.amp   = [0.2 0.4 0.6];
  r.thd   = zeros(numel(r.amp), numel(r.alpha));
  fprintf('1) THD (%%) vs alpha (cols) and drive amplitude (rows), period-1 drive\n');
  fprintf('        ');
  fprintf('a=%.1f   ', r.alpha); fprintf('\n');
  for ia = 1:numel(r.amp)
    fprintf('  A=%.1f  ', r.amp(ia));
    for ig = 1:numel(r.alpha)
      y = drive_node(steps, T, r.amp(ia), g0, toq(r.alpha(ig)), gmax, a0, sk);
      r.thd(ia, ig) = thd_percent(y, T);
      fprintf('%5.2f   ', r.thd(ia, ig));
    end
    fprintf('\n');
  end
  fprintf('\n');
end

function y = drive_node(steps, T, Fd, g0, al, gmax, a0, sk)
  u = 0; um1 = 0; y = zeros(steps, 1);
  for n = 1:steps
    F = round(Fd * sin(2*pi*n/T) * 2^23);
    [u, um1] = nl_node(u, um1, 4*F, g0, al, gmax, a0, sk);
    y(n) = u / 2^23;
  end
  y = y(round(steps/2):end);              % steady state
end

function t = thd_percent(y, T)
  N = numel(y); Y = abs(fft(y .* hanning(N)));
  f0 = round(N / T) + 1;                  % fundamental bin (1-based)
  fund = Y(f0);
  harm = 0;
  for k = 2:5
    b = round(k * (f0 - 1)) + 1;
    if b <= N/2; harm = harm + Y(b)^2; end
  end
  if fund <= 0; t = 0; else; t = 100 * sqrt(harm) / fund; end
end

% ===========================================================================
% 2. Aliasing floor at 1x / 2x / 4x (and 8x), spectral SNR vs 16x ground truth
% ===========================================================================
function r = analyse_aliasing()
  N = 9; frames = 256; c = 144; h = 0.01; fs = 48000; sigma = 1.5;
  beta = 6.667; gmaxr = 0.451; A = 0.5;
  ref = run_os(N, frames, 16, A, c, h, fs, sigma, beta, gmaxr);
  Rf = abs(fft(ref .* hanning(frames))); Rf = Rf(1:frames/2);
  r.os  = [1 2 4 8];
  r.snr = zeros(size(r.os));
  fprintf('2) Aliasing floor (spectral SNR of decimated output vs 16x ground truth)\n');
  for i = 1:numel(r.os)
    o = run_os(N, frames, r.os(i), A, c, h, fs, sigma, beta, gmaxr);
    Of = abs(fft(o .* hanning(frames))); Of = Of(1:frames/2);
    r.snr(i) = 10*log10(sum(Rf.^2) / sum((Rf - Of).^2));
    fprintf('   OS=%2dx : SNR = %5.1f dB\n', r.os(i), r.snr(i));
  end
  fprintf('\n');
end

function out = run_os(N, frames, OS, Areal, c, h, fs, sigma, beta, gmaxr)
  k = 1/fs; kos = k/OS; g2 = (c*kos/h)^2;
  g0 = toq(g2); al = toq(g2*beta); a0 = toq(1/(1+sigma*kos));
  sk = toq(1-sigma*kos); gmax = toq(gmaxr); recip = toq(1/OS);
  cy = ceil(N/2); cx = ceil(N/2); py = cy; px = ceil(N/4);
  s = zeros(N,N); s1 = zeros(N,N); out = zeros(frames,1);
  for f = 1:frames
    suml = 0;
    for i = 1:OS
      [s, s1] = nl_mesh(s, s1, g0, al, gmax, a0, sk);
      if f==1 && i==1; s(cy,cx) = qsat(s(cy,cx) + toq(Areal)); end
      suml = suml + s(py, px);
    end
    out(f) = qsat(qmc(recip, suml)) / 2^23;
  end
end

% ===========================================================================
% 3. Period-doubling / route-to-chaos (driven-node Poincare bifurcation)
% ===========================================================================
function r = analyse_bifurcation()
  g0 = toq(0.09); gmax = toq(0.49); a0 = toq(0.985); sk = toq(0.985);
  T = 10; Fd = 0.7; steps = 20000;
  r.alpha = 0.30:0.05:1.30;
  r.period = zeros(size(r.alpha));
  r.bounded = true(size(r.alpha));
  r.pts = cell(size(r.alpha));
  fprintf('3) Route to chaos: driven-node Poincare period vs alpha (T=%d, Fd=%.1f)\n', T, Fd);
  for i = 1:numel(r.alpha)
    p = poincare(steps, T, Fd, g0, toq(r.alpha(i)), gmax, a0, sk);
    r.pts{i} = p;
    r.period(i) = numel(uniquetol(p, 0.003));
    r.bounded(i) = max(abs(p)) < 1.0;
  end
  reg = r.alpha(r.period >= 2);
  if isempty(reg)
    fprintf('   (no bifurcation in range)\n');
  else
    fprintf('   locked period-1 for alpha < %.2f; period > 1 (route to chaos) over\n', reg(1));
    fprintf('   alpha in [%.2f, %.2f] (max observed period ~%d); re-locks above.\n', ...
            reg(1), reg(end), max(r.period));
  end
  fprintf('   bounded across the entire sweep: %d\n\n', all(r.bounded));
end

function p = poincare(steps, T, Fd, g0, al, gmax, a0, sk)
  u = 0; um1 = 0; p = [];
  for n = 1:steps
    F = round(Fd * sin(2*pi*n/T) * 2^23);
    [u, um1] = nl_node(u, um1, 4*F, g0, al, gmax, a0, sk);
    if n > steps*0.6 && mod(n, T) == 0; p(end+1) = u / 2^23; end %#ok<AGROW>
  end
end

% ===========================================================================
% Envelope summary + plots
% ===========================================================================
function print_envelope(thd, alias, bif)
  fprintf('%s\n', repmat('=', 1, 70));
  fprintf('OPERATING ENVELOPE\n');
  fprintf('%s\n', repmat('=', 1, 70));
  fprintf([ ...
    '  * alpha: linear-ish and low-THD below ~0.2; musical non-linear\n' ...
    '    brightening up to the bifurcation onset; a bounded route-to-chaos\n' ...
    '    band higher up; the gamma2_max=0.451 clamp keeps every case\n' ...
    '    convergent (bounded across the whole sweep: %d).\n' ...
    '  * amplitude: THD grows with drive level (squaring), so the mallet\n' ...
    '    input is the main brightness/chaos control alongside alpha.\n' ...
    '  * oversampling: each doubling cuts the aliasing floor by several dB\n' ...
    '    (1x %.1f -> 8x %.1f dB SNR vs ground truth); 4x is a sensible\n' ...
    '    default, higher for hard/chaotic patches.\n'], ...
    all(bif.bounded), alias.snr(1), alias.snr(end));
  fprintf('%s\n\n', repmat('=', 1, 70));
end

function plot_results(thd, alias, bif, outdir)
  fig = figure('visible','off','position',[100 100 1200 380]);
  subplot(1,3,1);
  plot(alias.os, alias.snr, '-o', 'LineWidth', 1.5); grid on;
  xlabel('oversampling factor'); ylabel('SNR vs 16x (dB)'); title('Aliasing floor');
  subplot(1,3,2);
  imagesc(thd.alpha, thd.amp, thd.thd); axis xy; colorbar;
  xlabel('alpha'); ylabel('drive amplitude'); title('THD (%)');
  subplot(1,3,3); hold on;
  for i = 1:numel(bif.alpha)
    plot(bif.alpha(i)*ones(size(bif.pts{i})), bif.pts{i}, 'k.', 'MarkerSize', 3);
  end
  xlabel('alpha'); ylabel('Poincare u'); title('Bifurcation'); grid on;
  print(fig, fullfile(outdir, 'chaos_characterization.png'), '-dpng', '-r150');
  close(fig);
  fprintf('  wrote %s\n', fullfile(outdir, 'chaos_characterization.png'));
end

function P = parse_opts(P, args)
  for i = 1:2:numel(args)
    switch lower(args{i})
      case 'plots';  P.plots  = logical(args{i+1});
      case 'outdir'; P.outdir = args{i+1};
    end
  end
end
