classdef Exciter < handle
    % Exciter  Physical excitation front-ends for the mesh (issue #33).
    %
    % Replaces the raw single-sample "mallet" strike with physical exciter
    % models that COUPLE to the surface: each step the exciter reads the surface
    % displacement at the excitation node and returns a force to inject there,
    % closing the interaction loop (milestone M9). Reference-model only; the
    % study vehicle for the RTL feasibility recommendation.
    %
    % Two types:
    %
    %  'mallet' : a lumped mass-spring contact (piano-hammer / Chaigne-Askenfelt
    %             style). Compression eta = uh - us; contact force
    %                 F = k * [eta]_+^p          (only while eta > 0)
    %             the hammer decelerates under -F/m and rebounds. HARDNESS = k:
    %             a stiffer spring gives a shorter contact and a brighter, more
    %             broadband strike; softer gives a longer, duller one. Contact
    %             time also shortens with strike velocity -> velocity-dependent
    %             brightness, the expressive core of a struck instrument.
    %
    %  'bow'    : a friction / stick-slip driver. Relative velocity
    %             vrel = vbow - vs (vs = surface velocity); friction force
    %                 F = Fn * sign(vrel) * (muD + (muS-muD) exp(-|vrel|/vc))
    %             The velocity-weakening (negative-slope) region sustains
    %             self-oscillation, a continuously driven, non-decaying tone
    %             (bowed metal / plate).
    %
    % Handle class: force() advances internal state in place.

    properties
        type
        dt
        % mallet
        m; k; p; uh; vh; contact
        % bow
        vbow; Fn; muS; muD; vc; us_prev
    end

    methods
        function obj = Exciter(type, fs, params)
            % params is a struct; sensible defaults per type below.
            obj.type = type;
            obj.dt   = 1.0 / fs;
            if nargin < 3; params = struct(); end

            switch type
                case 'mallet'
                    obj.m  = getdef(params, 'm', 0.02);   % hammer mass
                    obj.k  = getdef(params, 'k', 1e4);    % HARDNESS (stiffness)
                    obj.p  = getdef(params, 'p', 2.0);    % felt exponent
                    obj.uh = getdef(params, 'uh0', -0.02);% start below surface
                    obj.vh = getdef(params, 'vh0', 3.0);  % strike velocity (in)
                    obj.contact = false;
                case 'bow'
                    obj.vbow = getdef(params, 'vbow', 0.2);
                    obj.Fn   = getdef(params, 'Fn', 3.0);
                    obj.muS  = getdef(params, 'muS', 0.8);
                    obj.muD  = getdef(params, 'muD', 0.2);
                    obj.vc   = getdef(params, 'vc', 0.05);
                    obj.us_prev = 0.0;
                otherwise
                    error('Exciter:type', 'unknown exciter type "%s".', type);
            end
        end

        function F = force(obj, us)
            % us : surface displacement at the excitation node this step.
            switch obj.type
                case 'mallet'
                    eta = obj.uh - us;
                    if eta > 0
                        F = obj.k * eta ^ obj.p;
                        obj.contact = true;
                    else
                        F = 0.0;
                        obj.contact = false;
                    end
                    % hammer dynamics (semi-implicit Euler): -F decelerates it
                    obj.vh = obj.vh - (F / obj.m) * obj.dt;
                    obj.uh = obj.uh + obj.vh * obj.dt;

                case 'bow'
                    vs   = (us - obj.us_prev) / obj.dt;
                    vrel = obj.vbow - vs;
                    s    = sign(vrel);
                    if s == 0; s = 1; end
                    mu   = s * (obj.muD + (obj.muS - obj.muD) * exp(-abs(vrel) / obj.vc));
                    F    = obj.Fn * mu;
                    obj.us_prev = us;
            end
        end

        function tf = in_contact(obj)
            tf = strcmp(obj.type, 'mallet') && obj.contact;
        end
    end
end

function v = getdef(s, name, default)
    if isfield(s, name) && ~isempty(s.(name)); v = s.(name); else; v = default; end
end
