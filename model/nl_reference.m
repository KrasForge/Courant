function nl_reference(varargin)
% NL_REFERENCE  Verify the non-linear reference model against the RTL (#71).
%
% Two checks:
%   A. BIT-EXACT: a Q1.23 fixed-point emulation of the RTL node update
%      (node_element / node_update in fdtd_pkg) is run on the same 9x9 mesh,
%      coefficients and hard strike as nl_mesh_tb, and its stereo pickups are
%      compared to the committed golden trace src/tb/nl_mesh_trace.txt. They
%      must match every step, bit for bit, proving the reference reproduces the
%      RTL non-linear path exactly.
%   B. FLOAT MODEL: the float NLMesh2D (used for the demo audio) is driven with
%      the non-linearity on and a near-full-scale strike, and checked to stay
%      bounded (no divergence) and L/R symmetric on a symmetric mesh.
%
% Run: octave-cli --eval "nl_reference"

    here = fileparts(mfilename('fullpath'));
    trace = fullfile(here, '..', 'src', 'tb', 'nl_mesh_trace.txt');

    fprintf('\n=== Non-linear reference vs RTL (issue #71) ===\n');
    ok_a = check_bit_exact(trace);
    ok_b = check_float_model();

    assert(ok_a, 'nl_reference: fixed-point model does NOT match the golden trace');
    assert(ok_b, 'nl_reference: float model failed bounded/symmetric checks');
    fprintf('\nAll non-linear reference checks passed.\n');
end

% ===========================================================================
% A. Q1.23 fixed-point emulation regenerates the RTL golden trace bit-exactly
% ===========================================================================
function ok = check_bit_exact(trace)
    fprintf('\n--- A. Q1.23 fixed-point vs golden trace ---\n');

    % same setup as nl_mesh_tb: 9x9 fixed boundary, hard centred strike, NL on
    NX = 9; NY = 9; STEPS = 160;
    g2   = toq(0.09);  a0 = toq(0.99996875);  sk = toq(0.99996875);
    al   = toq(0.6);   gmax = toq(0.451);     IMP = toq(0.9);
    ex = 4; ey = 4;                 % 0-indexed excitation (centre)
    plx = 2; ply = 4; prx = 6; pry = 4;   % 0-indexed pickups

    U = zeros(NY, NX);  U1 = zeros(NY, NX);

    fid = fopen(trace, 'r');
    assert(fid > 0, 'cannot open %s', trace);
    fgetl(fid);                     % skip the header comment
    mism = 0;
    for k = 1:STEPS
        v = sscanf(fgetl(fid), '%d %d');  gL = v(1);  gR = v(2);
        Un = zeros(NY, NX);
        for i = 1:NY
            for j = 1:NX
                u = U(i,j);  u1 = U1(i,j);
                uN = 0; if i > 1,  uN = U(i-1,j); end
                uS = 0; if i < NY, uS = U(i+1,j); end
                uE = 0; if j < NX, uE = U(i,j+1); end
                uW = 0; if j > 1,  uW = U(i,j-1); end
                u2  = qmul(u, u);
                au2 = qmul(al, u2);
                g2l = clampi(satadd(g2, au2), 0, gmax);
                lap = uN + uS + uE + uW - 4*u;
                acc = 2*u - mulc(sk, u1) + mulc(g2l, lap);
                oacc = mulc(a0, acc);
                exch = 0;
                if k == 1 && (i-1) == ey && (j-1) == ex, exch = IMP; end
                Un(i,j) = sat(oacc + exch);
            end
        end
        U1 = U;  U = Un;
        if U(ply+1, plx+1) ~= gL || U(pry+1, prx+1) ~= gR
            mism = mism + 1;
        end
    end
    fclose(fid);

    if mism == 0
        fprintf('  160/160 steps BIT-EXACT with src/tb/nl_mesh_trace.txt\n');
        ok = true;
    else
        fprintf('  %d/160 steps MISMATCH\n', mism);
        ok = false;
    end
end

% ===========================================================================
% B. Float NLMesh2D: bounded + symmetric under the non-linearity
% ===========================================================================
function ok = check_float_model()
    fprintf('\n--- B. float NLMesh2D bounded + symmetric ---\n');
    NX = 9; NY = 9; fs = 48000;
    m = NLMesh2D(NX, NY, fs, 0.09, 0.6, 0.451, 1.5, 'fixed');   % NL on
    m.strike((NY-1)/2, (NX-1)/2, 1.5, 0.9);                     % hard centre strike
    bounded = true;  symmetric = true;
    for n = 1:400
        m.step();
        if max(abs(m.u(:))) > 1.0 || any(~isfinite(m.u(:))); bounded = false; end
        L = m.u(5, 3);  R = m.u(5, 7);                          % symmetric pickups
        if abs(L - R) > 1e-9; symmetric = false; end
    end
    fprintf('  bounded (|u| < 1 for 400 steps): %s\n', tf(bounded));
    fprintf('  L/R symmetric on a centred strike: %s\n', tf(symmetric));
    ok = bounded && symmetric;
end

% ===========================================================================
% Q1.23 fixed-point primitives (mirror fdtd_pkg exactly)
% ===========================================================================
function y = sat(x)      % saturate to Q1.23
    y = min(max(x, -2^23), 2^23 - 1);
end
function y = toq(x)      % real -> Q1.23 (round, saturate)
    y = sat(round(x * 2^23));
end
function y = shr(p)      % round-half-up then arithmetic >>23  (= shift_right)
    y = floor((p + 2^22) / 2^23);
end
function y = qmul(a, b)  % Q1.23 * Q1.23, round >>23, saturate
    y = sat(shr(a .* b));
end
function y = mulc(c, a)  % coeff * guard, round >>23, no saturation
    y = shr(c .* a);
end
function y = satadd(a, b)
    y = sat(a + b);
end
function y = clampi(x, lo, hi)
    y = min(max(x, lo), hi);
end

function s = tf(b)
    if b; s = 'yes'; else; s = 'NO'; end
end
