function mr_bems_main
%% MR-BEMS receding-horizon dispatch (Section 5.3 / 6.3)
% Requires: MATLAB R2020a+ with Optimization Toolbox (intlinprog).
% Outputs : results.mat -> then run make_metrics_figs.m
%           run_log.txt (full console transcript via diary)
rng('default');
diary('run_log.txt'); diary on;

%% ---------------- parameters (Tables A.1-A.4) ----------------
p.dt = 15/60;                       % h
p.Nday = round(24/p.dt);            % 96 steps/day
p.horizon = p.Nday;                 % 24-h receding window
p.simDays = 7;
p.T = p.simDays*p.Nday;

p.SOCstar = 0.80;
p.SOCmin  = 0.20;
p.SOCmax  = 0.95;

p.Tcrit = Inf;                       % deg C (declare surface or core in A.1, 45 or Inf)
p.Tamb  = 32;                       % deg C

p.PpumpMax = 1.471;                 % kW
p.PpumpMin = 0.12;                  % kW
p.PpurMax  = 0.12;                  % kW

p.Vmax   = 10;                      % m^3
p.V0frac = 0.50;                    % initial tank level, fraction of Vmax (item 6)
p.kq   = (10/3)/p.PpumpMax;         % ~2.266 m3/kWh at rated power
p.kpur = 0.5;                       % m3/kWh purifier  CALIBRATE (item 8)

p.eta    = 0.92;                    % per-leg efficiency  CALIBRATE
p.EpvDay = 28;                      % kWh/day PV          CALIBRATE

p.PdMax = 3.0;                      % kW
p.PdMin = 0.8;                      % kW
p.cDiesel = 3.0;                    % R$/kWh  CALIBRATE
p.wCurt   = 1.0;                    % R$ per kWh curtailed (equivalent value)
p.Mslack  = 1e3;                    % slack penalty weight (5.3); rename to Gamma in text

p.Enom   = 1.48;                    % kWh nominal per module (8 x P140 in series)
p.SoHeol = 0.40;                    % second-life EOL convention
p.kDeg   = 0.2/(3000*p.Enom);       % %-SoH fade per kWh throughput  CALIBRATE
p.kDegSourced = false;              % true only when kDeg has a cited source (item 3)
p.cDegBase = 0.10;                  % R$ per kWh throughput, fleet average  CALIBRATE
p.Crate = 1.0;
p.Vbus  = 29.6;

% ---- thermal sub-model: DATASHEET OR STEP-TEST VALUES ONLY (item 1) ----
p.kTh   = 15;                       % K/W  PLACEHOLDER -- see Appendix A.1
p.tauTh = 1800;                     % s    PLACEHOLDER -- see Appendix A.1
p.thermalSourced = false;           % set true once kTh/tauTh are sourced
p.isoTime = 4;
p.enableThermal = false;             % false = control run: no thermal model, no isolation

p.nexusGate    = 'batteryOnly';     % 'batteryOnly' | 'all'   (item 4)
p.busExclusive = true;              % per-bus charge/discharge exclusivity (item 2)
p.minAvailMod  = 1;                 % modules per bus that must stay available
p.dutyDailyCap = true;
p.dutyCarry    = true;              % subtract committed hours from today's budget
p.dutyHours    = 6;                 % h/day (5.2)
p.warmStart    = false;
p.auditFeas    = true;
p.failMode     = 'stop';
p.solverMaxTime = 600;

cI = struct('Crit',0,'BH',1,'BD',2,'Pump',3,'Pur',4,'Curt',5, ...
            'DisBH',6,'BatPump',7,'X',8,'Dies',9,'YP',10,'YD',11, ...
            'Eps',12,'Ws',13);
nx = 14;

%% ---------------- daily profiles ----------------
th = (0:p.Nday-1)*p.dt;
shape = max(0, sin(pi*(th-6)/12));
shape = shape/max(shape);
pvDay   = shape * p.EpvDay / (p.dt*sum(shape));
critDay = 0.0178 + 1.35*(th>=18 | th<6) + 0.05*(th>=8 & th<12);
dDay    = 3.33*((th>=7 & th<10) | (th>=18 & th<21));

Ppv   = repmat(pvDay(:),   p.simDays, 1);
Pcrit = repmat(critDay(:), p.simDays, 1);
Dwat  = repmat(dDay(:),    p.simDays, 1);
profiles = struct('Ppv',Ppv,'Pcrit',Pcrit,'Dwat',Dwat,'th',th);

fprintf('profile check: Ppv max %.3f kW | Pcrit min %.4f max %.4f | Dwat %.2f m3/day\n', ...
    max(Ppv), min(Pcrit), max(Pcrit), sum(dDay)*p.dt);

%% ---------------- modules & Stage-1 slicing ----------------
sohM = [62.302 62.358 62.359 62.384 62.387 62.422 62.458 62.469 62.490 ...
        67.595 67.628 67.648 67.686 67.689 67.706 67.761 67.764 67.785]/100;
dcir = [54.566 53.506 46.350 54.049 52.379 53.882 45.852 45.834 52.791 ...
        41.376 43.774 42.561 42.537 37.951 41.669 41.256 41.488 40.918];
% NOTE: synthetic healthy block removed -- never re-enable as measured data
nM = numel(sohM);

bus = zeros(1,nM);
bus(sohM >  0.65)                = 1;
bus(sohM <= 0.65 & sohM >= 0.55) = 2;
assert(all(bus>0), 'modulo fora das bandas de triagem -- revisar Apêndice A');

capM = p.Enom * sohM;               % sohM is already a fraction
assert(max(capM) < 1.5 && sum(capM) > 10, ...
       'capM scaling wrong: check Enom units and the /100 double-division bug');

lifeMult = 1 ./ max(sohM - p.SoHeol, 1e-3);
lifeMult = lifeMult / mean(lifeMult);
cDegM    = p.cDegBase * lifeMult;   % R$ per kWh throughput, per module

bank = struct('soh',sohM,'dcir',dcir,'bus',bus,'cap',capM, ...
              'lifeMult',lifeMult,'cDegM',cDegM);
fprintf('bank: %d modules | B_H %d (%.3f kWh) | B_D %d (%.3f kWh) | nominal %.3f kWh\n', ...
    nM, sum(bus==1), sum(capM(bus==1)), sum(bus==2), sum(capM(bus==2)), p.Enom*nM);
fprintf('degradation price: B_H %.4f | B_D %.4f | fleet %.4f R$/kWh throughput\n', ...
    mean(cDegM(bus==1)), mean(cDegM(bus==2)), mean(cDegM));

if p.enableThermal && ~p.thermalSourced
    fprintf(['\n*** WARNING: thermal model enabled with PLACEHOLDER kTh/tauTh. ' ...
             'Temperature, isolation and state-M4 columns are NOT reportable. ***\n\n']);
end

%% ---------------- scenarios ----------------
scen = struct;
scen.S1 = struct('slicing',false,'nexus',false);
scen.S2 = struct('slicing',true ,'nexus',false);
scen.S3 = struct('slicing',false,'nexus',true );
scen.S4 = struct('slicing',true ,'nexus',true );
scenList = {'S1','S2','S3','S4'};

%% ---------------- run ----------------
R = struct;
for si = 1:numel(scenList)
    scName = scenList{si};
    sc = scen.(scName);
    fprintf('--- scenario %s ---\n', scName);

    if sc.slicing
        capBHnom = sum(capM(bus==1));
        capBDnom = sum(capM(bus==2));
        cDegBH = mean(cDegM(bus==1));
        cDegBD = mean(cDegM(bus==2));
    else
        capBHnom = sum(capM);
        capBDnom = 0;
        cDegBH = mean(cDegM);
        cDegBD = 0;
    end
    capBH0 = capBHnom; capBD0 = capBDnom;

    EBH = 0.5*capBHnom;
    EBD = 0.5*max(capBDnom,eps);
    Vt  = p.V0frac*p.Vmax;

    Tmod  = p.Tamb*ones(1,nM);
    Tfree = p.Tamb*ones(1,nM);
    iso   = zeros(1,nM);
    uPrev = zeros(1,nx);
    hrsDay = zeros(1, p.simDays);

    nSolve = 0; tSolveTot = 0; nIsoEvents = 0; nAvailGuard = 0;
    nSimult = 0; failAt = NaN;

    R.(scName).step    = nan(p.T,nx);
    R.(scName).E       = nan(p.T,2);
    R.(scName).V       = nan(p.T,1);
    R.(scName).state   = zeros(p.T,1);
    R.(scName).tSolve  = nan(p.T,1);
    R.(scName).isoFrac = nan(p.T,1);
    R.(scName).gap     = nan(p.T,1);
    R.(scName).exitg   = nan(p.T,1);
    R.(scName).simult  = zeros(p.T,1);
    R.(scName).dies    = nan(p.T,1);
    R.(scName).Tmax    = nan(p.T,1);
    R.(scName).TclampPeak = nan(p.T,1);
    R.(scName).TrawPeak   = nan(p.T,1);
    R.(scName).TrawMean   = nan(p.T,1);
    R.(scName).TfreePeak  = nan(p.T,1);
    R.(scName).TfreeMean  = nan(p.T,1);
    R.(scName).PlossMax   = nan(p.T,1);
    R.(scName).epsMax     = nan(p.T,1);
    R.(scName).wsMax      = nan(p.T,1);
    R.(scName).PcapBH     = nan(p.T,1);
    R.(scName).PcapBD     = nan(p.T,1);
    R.(scName).capBH0  = capBH0;
    R.(scName).capBD0  = capBD0;
    R.(scName).V0      = Vt;
    R.(scName).nexusGate = p.nexusGate;

    tWall = tic;
    for k = 1:p.T
        w = k:min(k+p.horizon-1, p.T);
        N = numel(w);
        dayCur = ceil(k/p.Nday);

        if p.enableThermal
            [Tmod, iso, nNew, Traw, Tfree, PlossMax] = ...
                thermalMonitor(Tmod, iso, Tfree, uPrev, sc, bus, bank, p, cI);
            [iso, nGuard] = enforceAvailability(iso, bus, sc, p);
        else
            nNew = 0; nGuard = 0;
            Traw = p.Tamb*ones(1,nM); Tfree = Traw; PlossMax = 0;
            Tmod = Tfree; iso = zeros(1,nM);
        end
        nIsoEvents  = nIsoEvents + nNew;
        nAvailGuard = nAvailGuard + nGuard;

        R.(scName).TclampPeak(k) = max(Tmod);
        R.(scName).TrawPeak(k)   = max(Traw);
        R.(scName).TrawMean(k)   = mean(Traw);
        R.(scName).TfreePeak(k)  = max(Tfree);
        R.(scName).TfreeMean(k)  = mean(Tfree);
        R.(scName).PlossMax(k)   = PlossMax;
        R.(scName).Tmax(k)       = max(Traw);

        % isolation DERATES POWER; it does NOT remove energy capacity
        if sc.slicing
            capAvailBH = sum(capM(bus==1 & iso==0));
            capAvailBD = sum(capM(bus==2 & iso==0));
        else
            capAvailBH = sum(capM(iso==0));
            capAvailBD = 0;
        end
        PcapBH = p.Crate*max(capAvailBH, 1e-6);
        PcapBD = p.Crate*max(capAvailBD, 1e-6);

        EBH = min(max(EBH, p.SOCmin*capBHnom), p.SOCmax*capBHnom);
        EBD = min(max(EBD, p.SOCmin*max(capBDnom,1e-6)), p.SOCmax*max(capBDnom,1e-6));
        Vt  = min(max(Vt, 0), p.Vmax);

        R.(scName).PcapBH(k) = PcapBH;
        R.(scName).PcapBD(k) = PcapBD;

        in = struct('N',N,'p',p,'sc',sc,'cI',cI,'nx',nx, ...
                    'capBH',capBHnom,'capBD',max(capBDnom,1e-6), ...
                    'PcapBH',PcapBH,'PcapBD',PcapBD,'eta',p.eta, ...
                    'cDegBH',cDegBH,'cDegBD',cDegBD, ...
                    'E0BH',EBH,'E0BD',EBD,'V0',Vt, ...
                    'Ppv',Ppv(w)','Pcrit',Pcrit(w)','Dwat',Dwat(w)', ...
                    'prevU',uPrev,'kStart',k,'hrsToday',hrsDay(dayCur));

        [u, EBH, EBD, Vt, stats] = solveWindow(in);

        R.(scName).gap(k)   = stats.gap;
        R.(scName).exitg(k) = stats.exit;

        if ~stats.ok
            fprintf(['   SOLVER FAILURE at k=%d (scenario %s, exitflag %d). ' ...
                     'No control committed.\n'], k, scName, stats.exit);
            failAt = k;
            if strcmp(p.failMode,'stop'), break; end
            u = zeros(1,nx); u(1+cI.Eps) = Pcrit(k); stats.tSolve = 0;
        end

        chBH = u(1+cI.BH);
        if sc.slicing
            disBH = u(1+cI.DisBH);
            chBD  = u(1+cI.BD);
            disBD = u(1+cI.BatPump);
        else
            disBH = u(1+cI.DisBH) + u(1+cI.BatPump);
            chBD  = 0; disBD = 0;
        end
        simul = (chBH > 1e-6 && disBH > 1e-6) || (chBD > 1e-6 && disBD > 1e-6);
        R.(scName).simult(k) = double(simul);
        nSimult = nSimult + simul;

        uPrev = u;
        hrsDay(dayCur) = hrsDay(dayCur) + p.dt*u(1+cI.YP);
        nSolve = nSolve+1;
        tSolveTot = tSolveTot + stats.tSolve;

        R.(scName).dies(k)     = u(1+cI.Dies);
        R.(scName).step(k,:)   = u;
        R.(scName).E(k,:)      = [EBH EBD];
        R.(scName).V(k)        = Vt;
        R.(scName).tSolve(k)   = stats.tSolve;
        R.(scName).isoFrac(k)  = sum(iso>0)/nM;
        R.(scName).state(k)    = assignState(u, Ppv(k), EBH/capBHnom, any(iso>0), p, cI);
        R.(scName).epsMax(k)   = u(1+cI.Eps);
        R.(scName).wsMax(k)    = u(1+cI.Ws);
    end

    R.(scName).wall = toc(tWall);
    R.(scName).nIsoEvents  = nIsoEvents;
    R.(scName).nAvailGuard = nAvailGuard;
    R.(scName).nSimult     = nSimult;
    R.(scName).failAt      = failAt;
    R.(scName).hrsDay      = hrsDay;
    R.(scName).Vend        = Vt;
    R.(scName).thermalSourced = p.thermalSourced;

    %% ---- per-scenario report ----
    g = R.(scName).gap(~isnan(R.(scName).gap));
    if isempty(g)
        fprintf('   gap: nao registado em nenhum solve\n');
    else
        fprintf('   gap relativo: medio %.3e | maximo %.3e | solves com gap %d/%d\n', ...
            mean(g), max(g), numel(g), nSolve);
    end

    nSolved = sum(R.(scName).exitg == 1);
    minSOCBH = min(R.(scName).E(:,1),[],'omitnan')/capBH0;
    if capBD0 > 0
        minSOCBD = min(R.(scName).E(:,2),[],'omitnan')/capBD0;
    else
        minSOCBD = NaN;
    end
    epsMax  = max(R.(scName).epsMax,[],'omitnan');
    wsMax   = max(R.(scName).wsMax,[],'omitnan');
    nEpsTol = sum(R.(scName).epsMax > 1e-3);
    PLmx    = max(R.(scName).PlossMax,[],'omitnan');
    TssMax  = p.Tamb + p.kTh*PLmx;
    PcapMin = min(R.(scName).PcapBH,[],'omitnan');

    fprintf('   exitflag==1: %d/%d | failAt %s | diesel %.2f kWh | duty %.2f h\n', ...
        nSolved, nSolve, num2str(failAt), ...
        p.dt*sum(R.(scName).dies,'omitnan'), ...
        p.dt*sum(R.(scName).step(:,1+cI.YP),'omitnan'));
    fprintf('   min SOC_BH %.3f (floor %.2f) | min SOC_BD %.3f | iso events %d | avail guards %d\n', ...
        minSOCBH, p.SOCmin, minSOCBD, nIsoEvents, nAvailGuard);
    fprintf('   simultaneous charge+discharge steps: %d/%d (busExclusive=%d)\n', ...
        nSimult, nSolve, p.busExclusive);
    fprintf('   duty per day: %s h (cap %.1f h/day)\n', ...
        num2str(hrsDay,'%.2f '), p.dutyHours);
    fprintf(['   T: clamped peak %.2f | raw peak %.2f mean %.2f | ' ...
             'free-run peak %.2f mean %.2f C (thermalSourced=%d)\n'], ...
        max(R.(scName).TclampPeak,[],'omitnan'), ...
        max(R.(scName).TrawPeak,[],'omitnan'), ...
        mean(R.(scName).TrawMean,'omitnan'), ...
        max(R.(scName).TfreePeak,[],'omitnan'), ...
        mean(R.(scName).TfreeMean,'omitnan'), p.thermalSourced);
    fprintf('   eps max %.3e (steps >1e-3: %d/%d) | ws max %.3e\n', ...
        epsMax, nEpsTol, nSolve, wsMax);
    fprintf('   thermal: max per-module loss %.3f W | implied Tss %.2f C (Tcrit %.0f)\n', ...
        PLmx, TssMax, p.Tcrit);
    fprintf('   water: V0 %.3f -> Vf %.3f m3 (drawdown %.3f) | pumped %.3f | purif %.3f | unmet %.3f\n', ...
        p.V0frac*p.Vmax, Vt, p.V0frac*p.Vmax - Vt, ...
        p.kq*p.dt*sum(R.(scName).step(:,1+cI.X)), ...
        p.kpur*p.dt*sum(R.(scName).step(:,1+cI.Pur)), ...
        p.dt*sum(R.(scName).wsMax));
    fprintf('   bus power ceiling: min Pcap_BH %.3f kW\n', PcapMin);
    if capBD0 > 0
        resE = (p.SOCmax-p.SOCmin)*capBD0;
        fprintf(['   B_D throughput %.3f kWh (held reserve) | usable %.3f kWh | ' ...
                 'sustains peak critical load %.2f h\n'], ...
            p.dt*sum(R.(scName).step(:,3)+R.(scName).step(:,8)), ...
            resE, resE/max(Pcrit));
    end
    fprintf(' done in %.1f s | %d MILP solves | avg %.2f s/solve\n', ...
        R.(scName).wall, nSolve, tSolveTot/max(nSolve,1));
end

%% ---------------- consolidated summary ----------------
fprintf('\n===== SUMMARY — send this block =====\n');
fprintf('%-4s %9s %9s %7s %7s %8s %8s %9s %11s %11s %9s %6s %8s %8s\n', ...
    'Scen','minSocBH','minSocBD','failAt','isoEv','TrawPk','TfreePk','TfreeMn', ...
    'epsMax','wsMax','GapMax','simul','Vf','diesel');
for si = 1:numel(scenList)
    s = scenList{si}; m = R.(s);
    g = m.gap(~isnan(m.gap));
    if m.capBD0 > 0
        sBD = min(m.E(:,2),[],'omitnan')/m.capBD0;
    else
        sBD = NaN;
    end
    fprintf('%-4s %9.3f %9.3f %7s %7d %8.2f %8.2f %9.2f %11.3e %11.3e %9.2e %6d %8.3f %8.2f\n', ...
        s, min(m.E(:,1),[],'omitnan')/m.capBH0, sBD, num2str(m.failAt), ...
        m.nIsoEvents, max(m.TrawPeak,[],'omitnan'), ...
        max(m.TfreePeak,[],'omitnan'), mean(m.TfreeMean,'omitnan'), ...
        max(m.epsMax,[],'omitnan'), max(m.wsMax,[],'omitnan'), max(g), ...
        m.nSimult, m.Vend, p.dt*sum(m.dies,'omitnan'));
end
fprintf('====================================\n\n');

save('results.mat','p','R','bank','profiles');
fprintf('Saved results.mat. Now run make_metrics_figs.m\n');
diary off;
end

% =====================================================================
function [Tmod, iso, nNew, Traw, Tfree, PlossMax] = ...
         thermalMonitor(Tmod, iso, Tfree, uPrev, sc, bus, bank, p, cI)
% Local function: must sit at the end of the file, never inside a loop.
% Uses NET bus power so a charging and a discharging path cannot be summed.
dtS = p.dt*3600;
nModTot = numel(bank.soh);
nNew = 0;
Ploss = zeros(1,nModTot);

if ~isempty(uPrev) && any(uPrev>0)
    if sc.slicing
        PBH = abs(uPrev(1+cI.DisBH) - uPrev(1+cI.BH));
        PBD = abs(uPrev(1+cI.BatPump) - uPrev(1+cI.BD));
    else
        PBH = abs(uPrev(1+cI.DisBH) + uPrev(1+cI.BatPump) - uPrev(1+cI.BH));
        PBD = 0;
    end
    for i = 1:nModTot
        if sc.slicing
            if bus(i) == 1
                Pb = PBH; nMod = max(sum(bus==1),1);
            else
                Pb = PBD; nMod = max(sum(bus==2),1);
            end
        else
            Pb = PBH; nMod = nModTot;
        end
        if iso(i) > 0
            Ploss(i) = 0;
        else
            Imod = (Pb*1000)/p.Vbus/nMod;
            Ploss(i) = Imod^2*(bank.dcir(i)/1000);
        end
        Tss  = p.Tamb + p.kTh*Ploss(i);
        a    = exp(-dtS/p.tauTh);
        Tmod(i)  = Tss + a*(Tmod(i)  - Tss);
        Tfree(i) = Tss + a*(Tfree(i) - Tss);
    end
end

PlossMax = max(Ploss);
Traw = Tmod;
iso(iso>0) = iso(iso>0) - 1;
newly = (Tmod >= p.Tcrit) & (iso == 0);
iso(newly) = p.isoTime;
nNew = sum(newly);
Tmod(newly) = p.Tcrit;
end

% =====================================================================
function [iso, nGuard] = enforceAvailability(iso, bus, sc, p)
% Keep at least p.minAvailMod modules available in every bus.
nGuard = 0;
if ~any(iso>0), return; end
if sc.slicing
    for b = [1 2]
        idx = find(bus==b);
        if isempty(idx), continue; end
        nReq = min(p.minAvailMod, numel(idx));
        nAvail = sum(iso(idx)==0);
        while nAvail < nReq
            cand = idx(iso(idx)>0);
            if isempty(cand), break; end
            [~, jj] = min(iso(cand));
            iso(cand(jj)) = 0;
            nAvail = nAvail + 1;
            nGuard = nGuard + 1;
        end
    end
else
    nReq = min(p.minAvailMod, numel(iso));
    nAvail = sum(iso==0);
    while nAvail < nReq
        cand = find(iso>0);
        if isempty(cand), break; end
        [~, jj] = min(iso(cand));
        iso(cand(jj)) = 0;
        nAvail = nAvail + 1;
        nGuard = nGuard + 1;
    end
end
end

% =====================================================================
function [u, EBH1, EBD1, V1, stats] = solveWindow(in)
% Stage 2 -- one receding-horizon MILP (Algorithm 2, Section 5.3).
p = in.p; sc = in.sc; N = in.N; dt = p.dt; c = in.cI; nx = in.nx;

% ---- decision-vector layout (single source of truth) ----
%  [1 .. nx*N]                            controls, offsets j = 0..nx-1
%  [nC+1 .. nC+(N+1)]                     E_BH,  t = 0..N
%  [nC+(N+1)+1 .. nC+2(N+1)]              E_BD,  t = 0..N   (slicing only)
%  [nC+(N+1)*nE+1 .. nC+(N+1)*(nE+1)]     V_tank, t = 0..N
%  [nv0+1 .. nv]                          binaries
nC   = nx*N;                            % control block width
nE   = 1 + double(sc.slicing);          % number of BATTERY state groups
nG   = nE + 1;                          % battery groups + tank group
nv0  = nC + (N+1)*nG;                   % length of the whole state block
zeroCyc = sc.slicing && sc.nexus;       % B_D held as reserve in the full system

if sc.slicing
    PcapPump = in.PcapBD;
    cDegPump = in.cDegBD;
else
    PcapPump = in.PcapBH;
    cDegPump = in.cDegBH;
end

useNex = sc.nexus && (~zeroCyc || strcmpi(p.nexusGate,'all'));
nChG   = 1 + double(sc.slicing);
nB     = N*(nChG + double(useNex));
nv     = nv0 + nB;

blk   = @(k,j) (k-1)*nx + (1+j);
eBH   = @(k) nC + k;
eBD   = @(k) nC + (N+1) + k;
eV    = @(k) nC + (N+1)*nE + k;
iChBH = @(k) nv0 + k;
iChBD = @(k) nv0 + N + k;
iNex  = @(k) nv0 + N*nChG + k;

% ---- block-boundary checks: catch an offset slip before any matrix is built ----
% blk covers j = 0..nx-1, so its last index is blk(N, nx-1) == nC
assert(blk(1,0) == 1 && blk(N,nx-1) == nC, ...
    'control block mismatch: blk(1,0)=%d blk(N,nx-1)=%d nC=%d', ...
    blk(1,0), blk(N,nx-1), nC);
assert(eBH(1) == nC + 1 && eBH(N+1) == nC + (N+1), 'E_BH block mismatch');
if sc.slicing
    assert(eBD(1) == nC + (N+1) + 1 && eBD(N+1) == nC + 2*(N+1), 'E_BD block mismatch');
end
assert(eV(1) == nC + (N+1)*nE + 1, 'V_tank start mismatch: eV(1)=%d', eV(1));
assert(eV(N+1) == nv0, 'energy-state block offset mismatch: eV(N+1)=%d nv0=%d', eV(N+1), nv0);
maxBin = iChBH(N);
if sc.slicing, maxBin = max(maxBin, iChBD(N)); end
if useNex,     maxBin = max(maxBin, iNex(N));  end
assert(maxBin == nv, 'binary block mismatch: maxBin=%d nv=%d', maxBin, nv);

% ---- objective: all terms in R$ or R$-equivalent, all per step ----
f = zeros(nv,1);
for k = 1:N
    f(blk(k,c.Curt))    = p.wCurt*dt;
    f(blk(k,c.Dies))    = p.cDiesel*dt;
    f(blk(k,c.Eps))     = p.Mslack*dt;
    f(blk(k,c.Ws))      = p.Mslack*dt;
    f(blk(k,c.BH))      = in.cDegBH*dt;
    f(blk(k,c.DisBH))   = in.cDegBH*dt;
    f(blk(k,c.BD))      = in.cDegBD*dt;
    f(blk(k,c.BatPump)) = cDegPump*dt;
end

% ---- equality constraints ----
erows = {};
for k = 1:N
    erows{end+1,1} = {[blk(k,c.Crit) blk(k,c.BH) blk(k,c.BD) blk(k,c.Pump) ...
                       blk(k,c.Pur) blk(k,c.Curt)], ones(1,6), in.Ppv(k)};

    erows{end+1,1} = {[blk(k,c.Crit) blk(k,c.DisBH) blk(k,c.Dies) blk(k,c.Eps)], ...
                      ones(1,4), in.Pcrit(k)};

    erows{end+1,1} = {[blk(k,c.X) blk(k,c.Pump) blk(k,c.BatPump)], [1 -1 -1], 0};

    col = [eBH(k+1) eBH(k) blk(k,c.BH) blk(k,c.DisBH)];
    cof = [1 -1 -in.eta*dt dt];
    if ~sc.slicing
        col = [col blk(k,c.BatPump)];
        cof = [cof dt];
    end
    erows{end+1,1} = {col, cof, 0};

    if sc.slicing
        erows{end+1,1} = {[eBD(k+1) eBD(k) blk(k,c.BD) blk(k,c.BatPump)], ...
                          [1 -1 -in.eta*dt dt], 0};
    end

    erows{end+1,1} = {[eV(k+1) eV(k) blk(k,c.X) blk(k,c.Pur) blk(k,c.Ws)], ...
                      [1 -1 -p.kq*dt -p.kpur*dt -dt], -in.Dwat(k)*dt};
end
erows{end+1,1} = {eBH(1), 1, in.E0BH};
if sc.slicing
    erows{end+1,1} = {eBD(1), 1, in.E0BD};
end
erows{end+1,1} = {eV(1), 1, in.V0};

% ---- inequality constraints ----
irows = {};
for k = 1:N
    irows{end+1,1} = {[blk(k,c.X) blk(k,c.YP)], [1 -p.PpumpMax], 0};
    irows{end+1,1} = {[blk(k,c.X) blk(k,c.YP)], [-1 p.PpumpMin], 0};

    irows{end+1,1} = {[blk(k,c.Dies) blk(k,c.YD)], [1 -p.PdMax], 0};
    irows{end+1,1} = {[blk(k,c.Dies) blk(k,c.YD)], [-1 p.PdMin], 0};

    if p.busExclusive
        % yCh = 1 -> charging allowed; yCh = 0 -> discharging allowed
        irows{end+1,1} = {[blk(k,c.BH) iChBH(k)], [1 -in.Ppv(k)], 0};
        if sc.slicing
            irows{end+1,1} = {[blk(k,c.DisBH) iChBH(k)], [1 in.PcapBH], in.PcapBH};
            irows{end+1,1} = {[blk(k,c.BD) iChBD(k)], [1 -in.Ppv(k)], 0};
            irows{end+1,1} = {[blk(k,c.BatPump) iChBD(k)], [1 in.PcapBD], in.PcapBD};
        else
            irows{end+1,1} = {[blk(k,c.DisBH) blk(k,c.BatPump) iChBH(k)], ...
                              [1 1 in.PcapBH], in.PcapBH};
        end
    end

    if useNex
        if strcmpi(p.nexusGate,'all')
            irows{end+1,1} = {[blk(k,c.X) iNex(k)], [1 -p.PpumpMax], 0};
        else
            irows{end+1,1} = {[blk(k,c.BatPump) iNex(k)], [1 -PcapPump], 0};
        end
        irows{end+1,1} = {[eBH(k) iNex(k)], [-1 in.capBH], in.capBH*(1-p.SOCstar)};
    end
end

% pump duty limit: rolling daily cap across committed steps
if p.dutyDailyCap
    kWin   = in.kStart:(in.kStart+N-1);
    dayIdx = ceil(kWin/p.Nday);
    day0   = ceil(in.kStart/p.Nday);
    for d = unique(dayIdx)
        kkD = kWin(dayIdx==d);
        cols = zeros(1,numel(kkD));
        for j = 1:numel(kkD)
            cols(j) = blk(kkD(j)-in.kStart+1, c.YP);
        end
        if p.dutyCarry && d == day0
            budget = p.dutyHours - in.hrsToday;
        else
            budget = p.dutyHours;
        end
        irows{end+1,1} = {cols, ones(1,numel(cols)), max(budget,0)/dt};
    end
else
    cols = zeros(1,N);
    for k = 1:N
        cols(k) = blk(k,c.YP);
    end
    irows{end+1,1} = {cols, ones(1,N), p.dutyHours/dt};
end

% ---- assemble (single pass; no row-growth idiom) ----
ne = size(erows,1);
Ae = zeros(ne,nv); be = zeros(ne,1);
for r = 1:ne
    Ae(r, erows{r}{1}) = erows{r}{2};
    be(r) = erows{r}{3};
end

ni = size(irows,1);
Ai = zeros(ni,nv); bi = zeros(ni,1);
for r = 1:ni
    Ai(r, irows{r}{1}) = irows{r}{2};
    bi(r) = irows{r}{3};
end

assert(size(Ae,2)==nv && size(Ai,2)==nv, ...
    'constraint width mismatch: Ae %dx%d | Ai %dx%d | nv %d | nv0 %d | N %d', ...
    size(Ae,1), size(Ae,2), size(Ai,1), size(Ai,2), nv, nv0, N);

% ---- bounds ----
lb = zeros(nv,1);
ub = inf(nv,1);
for k = 1:N
    ub(blk(k,c.Crit))    = in.Ppv(k);
    ub(blk(k,c.BH))      = in.Ppv(k);
    ub(blk(k,c.BD))      = in.Ppv(k)*(sc.slicing && ~sc.nexus);
    ub(blk(k,c.Pump))    = p.PpumpMax;
    ub(blk(k,c.Pur))     = p.PpurMax;
    ub(blk(k,c.Curt))    = in.Ppv(k);
    ub(blk(k,c.DisBH))   = in.PcapBH;
    ub(blk(k,c.BatPump)) = PcapPump*~zeroCyc;
    ub(blk(k,c.X))       = p.PpumpMax;
    ub(blk(k,c.Dies))    = p.PdMax;
    ub(blk(k,c.YP))      = 1;
    ub(blk(k,c.YD))      = 1;
    ub(blk(k,c.Eps))     = in.Pcrit(k);
    ub(blk(k,c.Ws))      = in.Dwat(k);
end
ub(iChBH(1:N)) = 1;
if sc.slicing, ub(iChBD(1:N)) = 1; end
if useNex,     ub(iNex(1:N))  = 1; end

lb(eBH(1:N+1)) = p.SOCmin*in.capBH; ub(eBH(1:N+1)) = p.SOCmax*in.capBH;
if sc.slicing
    lb(eBD(1:N+1)) = p.SOCmin*in.capBD; ub(eBD(1:N+1)) = p.SOCmax*in.capBD;
end
lb(eV(1:N+1)) = 0;
ub(eV(1:N+1)) = p.Vmax;

% ---- NaN screen ----
modelNaN = false;
chk = {'f',f;'be',be;'bi',bi;'lb',lb;'ub',ub};
for ii = 1:size(chk,1)
    if any(isnan(chk{ii,2}(:)))
        fprintf('   NaN detected in %s (k=%d)\n', chk{ii,1}, in.kStart);
        modelNaN = true;
    end
end
if any(isnan(Ai(:))) || any(isnan(Ae(:)))
    fprintf('   NaN detected in Ai/Ae (k=%d)\n', in.kStart);
    modelNaN = true;
end
if any(isnan([in.Ppv in.Pcrit in.Dwat in.E0BH in.E0BD in.V0 in.capBH in.capBD]))
    fprintf('   NaN detected in inputs (k=%d)\n', in.kStart);
    modelNaN = true;
end

% ---- feasibility witness ----
if p.auditFeas
    xc = zeros(nv,1);
    for k = 1:N
        xc(blk(k,c.Curt)) = in.Ppv(k);
        xc(blk(k,c.Eps))  = in.Pcrit(k);
        xc(blk(k,c.Ws))   = in.Dwat(k);
        xc(eBH(k))        = in.E0BH;
        xc(eV(k))         = in.V0;
        if sc.slicing, xc(eBD(k)) = in.E0BD; end
        xc(iChBH(k)) = 1;                       % charging-allowed branch
        if sc.slicing, xc(iChBD(k)) = 1; end
        % iNex stays 0: gate satisfied by not pumping from the battery
    end
    xc(eBH(N+1)) = in.E0BH;
    xc(eV(N+1))  = in.V0;
    if sc.slicing, xc(eBD(N+1)) = in.E0BD; end

    rEq = max(abs(Ae*xc - be));
    rIq = max(Ai*xc - bi);
    rBd = max([lb - xc; xc - ub]);
    if rEq > 1e-8 || rIq > 1e-8 || rBd > 1e-8
        fprintf(['   AUDIT FAIL k=%d: eq %.3e | ineq %.3e | bound %.3e | ' ...
                 'E0BH %.4f (lb %.4f ub %.4f) | E0BD %.4f | V0 %.4f (ub %.4f) | ' ...
                 'capBH %.4f | nv %d | nv0 %d\n'], ...
            in.kStart, rEq, rIq, rBd, in.E0BH, lb(eBH(1)), ub(eBH(1)), ...
            in.E0BD, in.V0, p.Vmax, in.capBH, nv, nv0);
    end
end

% ---- integer variables ----
intcon = zeros(1, 2*N + N*nChG + N*double(useNex));
for k = 1:N
    intcon(2*k-1) = blk(k,c.YP);
    intcon(2*k)   = blk(k,c.YD);
end
cnt = 2*N;
for k = 1:N, cnt = cnt+1; intcon(cnt) = iChBH(k); end
if sc.slicing
    for k = 1:N, cnt = cnt+1; intcon(cnt) = iChBD(k); end
end
if useNex
    for k = 1:N, cnt = cnt+1; intcon(cnt) = iNex(k); end
end
assert(max(intcon) <= nv, 'intcon index %d exceeds nv %d', max(intcon), nv);

% ---- warm start ----
x0 = [];
if p.warmStart
    x0 = lb;
    for k = 1:N
        x0(blk(k,c.YP)) = in.prevU(1+c.YP);
        x0(blk(k,c.YD)) = in.prevU(1+c.YD);
        x0(iChBH(k))    = 1;
        if sc.slicing, x0(iChBD(k)) = 1; end
        if useNex,     x0(iNex(k))  = 1; end
    end
end

opts = optimoptions('intlinprog','Display','off','MaxTime',p.solverMaxTime, ...
                    'AbsoluteGapTolerance',1e-4);

tt = tic;
if isempty(x0)
    [x,~,exitflag,out] = intlinprog(f,intcon,Ai,bi,Ae,be,lb,ub,opts);
else
    [x,~,exitflag,out] = intlinprog(f,intcon,Ai,bi,Ae,be,lb,ub,x0,opts);
end
stats.tSolve = toc(tt);
stats.exit   = exitflag;
stats.gap    = NaN;
stats.ok     = false;

if exitflag > 0 && ~isempty(x) && numel(x) == nv
    stats.ok = true;
    u    = x(1:nx).';
    EBH1 = x(eBH(2));
    V1   = x(eV(2));
    if sc.slicing, EBD1 = x(eBD(2)); else, EBD1 = in.E0BD; end
    if isfield(out,'relativegap'), stats.gap = out.relativegap; end
else
    fprintf(['   intlinprog exitflag %d at k=%d | nv=%d | nv0=%d | nAineq=%d | ' ...
             'nAeq=%d | modelNaN=%d | nBin=%d | T left=%d\n'], ...
        exitflag, in.kStart, nv, nv0, size(Ai,1), size(Ae,1), modelNaN, ...
        numel(intcon), numel(in.Ppv));
    u = zeros(1,nx);
    EBH1 = in.E0BH; EBD1 = in.E0BD; V1 = in.V0;
end
end

% =====================================================================
function st = assignState(u, PpvNow, SOCBH, isoAny, p, cI)
% Operating-state tag (Table 3, Section 4.4): 1=M1 2=M2 3=M3 4=M4 5=D 6=F
if isoAny
    st = 4;                         % M4 THERMAL_ISOLATION
elseif u(1+cI.Dies) > 1e-6
    st = 6;                         % F DIESEL_BACKUP
elseif PpvNow > 0.01
    if SOCBH >= p.SOCstar
        st = 2;                     % M2 NEXUS_SURPLUS
    elseif u(1+cI.Curt) > 1e-6
        st = 5;                     % D CURTAILMENT
    else
        st = 1;                     % M1 CRITICAL_CHARGE
    end
else
    st = 3;                         % M3 NIGHT_DISCHARGE
end
end