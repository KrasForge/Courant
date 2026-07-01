function compare_capture(capture_wav, varargin)
% COMPARE_CAPTURE  Compare an on-board audio capture to the simulation reference.
%
% Turnkey harness for the hardware-validation step of issue #27: once you have
% recorded the board's audio output to a WAV file, this measures how faithfully
% it reproduces the simulation impulse response and reports the end-to-end
% latency (excitation in -> audio out) by cross-correlation.
%
% It does NOT need the FPGA to run; it compares two WAV files. Generate the
% reference first with fdtd_ref (writes outputs/impulse_<bc>.wav), capture the
% board output to a WAV at the same sample rate, then run this.
%
% Usage:
%   compare_capture('board_strike.wav')                       % vs fixed-bc ref
%   compare_capture('board_strike.wav', 'ref', 'outputs/impulse_free.wav')
%   compare_capture('board_strike.wav', 'fs', 48000)
%
% Name/value options:
%   'ref'  (char) reference WAV            [default outputs/impulse_fixed.wav]
%   'fs'   (Hz)   expected sample rate     [default read from the files]
%   'chan' (int)  channel to compare (1=L) [default 1]
%
% Reports:
%   * measured latency (samples and ms) = argmax of the cross-correlation;
%   * normalised RMS error of the latency-aligned, amplitude-normalised traces;
%   * a PASS/FAIL against a loose recognisability threshold (the codec, analog
%     path and room add colour, so this is a similarity check, not bit-exact).

    p = inputParser;
    p.addRequired('capture_wav', @ischar);
    p.addParameter('ref', fullfile('outputs', 'impulse_fixed.wav'), @ischar);
    p.addParameter('fs', 0, @isnumeric);
    p.addParameter('chan', 1, @isnumeric);
    p.parse(capture_wav, varargin{:});
    opt = p.Results;

    [cap, fs_cap] = audioread(opt.capture_wav);
    [ref, fs_ref] = audioread(opt.ref);

    if fs_cap ~= fs_ref
        error('compare_capture:fs', ...
              'sample-rate mismatch: capture %d Hz, reference %d Hz', ...
              fs_cap, fs_ref);
    end
    fs = fs_cap;
    if opt.fs > 0 && fs ~= opt.fs
        warning('compare_capture:fsExpected', ...
                'files are %d Hz, expected %d Hz', fs, opt.fs);
    end

    c = cap(:, min(opt.chan, size(cap, 2)));
    r = ref(:, min(opt.chan, size(ref, 2)));

    % zero-mean, unit-energy so amplitude/level differences do not dominate
    c = c - mean(c);  c = c / (norm(c) + eps);
    r = r - mean(r);  r = r / (norm(r) + eps);

    % cross-correlation via conv (base Octave/MATLAB, no signal package needed):
    % xcorr(c, r) = conv(c, flipud(r)), full lags -(numel(r)-1) .. (numel(c)-1).
    xc   = conv(c, flipud(r));
    lags = (-(numel(r) - 1) : (numel(c) - 1))';
    [~, k]     = max(abs(xc));
    lag        = lags(k);                 % samples the capture trails the ref
    lat_ms     = 1000 * lag / fs;

    % align on the measured lag, then normalised RMS error over the overlap
    if lag >= 0
        a = c(lag+1:end);  b = r(1:numel(a));
    else
        b = r(-lag+1:end); a = c(1:numel(b));
    end
    n = min(numel(a), numel(b));
    a = a(1:n); b = b(1:n);
    nrmse = norm(a - b) / (norm(b) + eps);
    xcorr_peak = xc(k) / (norm(c) * norm(r) + eps);

    fprintf('\n=== compare_capture: board vs simulation ===\n');
    fprintf('  reference      : %s (%d Hz)\n', opt.ref, fs);
    fprintf('  capture        : %s\n', opt.capture_wav);
    fprintf('  latency (lag)  : %d samples = %.3f ms\n', lag, lat_ms);
    fprintf('  xcorr peak     : %.3f (1.0 = identical shape)\n', xcorr_peak);
    fprintf('  normalised RMSE: %.3f\n', nrmse);

    % Loose recognisability gate: shape correlates and error is bounded. The
    % analog path is not bit-exact, so this is deliberately generous.
    pass = (xcorr_peak >= 0.7) && (nrmse <= 0.5);
    if pass
        fprintf('  RESULT         : PASS (recognisable, well-aligned)\n\n');
    else
        fprintf('  RESULT         : REVIEW (low correlation or high error)\n\n');
    end
end
