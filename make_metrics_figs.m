function make_metrics_figs
%% make_metrics_figs.m — paper figures + tables from results.mat
% Requires: results.mat produced by mr_bems_main.m
% Outputs : results_metrics.tex      (energy / water / RUL metrics)
%           results_diagnostics.tex  (gap, exitflag, Tmax, diesel, duty, closure)
%           fig_representative_day_<scenario>.(pdf|png)
%           fig_scenarios_composite.(pdf|png)

S = load('results.mat');
p = S.p; R = S.R; bank = S.bank; pr = S.profiles;
dt = p.dt; T = p.T; nDay = p.Nday;

% ---- fixed scenario order S1..S4 (independent of execution order) ----
scenList = sort(fieldnames(R));

% ---- energy carriers per module (kWh nominal) ----
Enom = p.Enom;                                    % 1.48 kWh (8 x P140 in series)
EolSoH = 0.40;                                    % second-life EOL convention

metrics = struct;

for si = 1:numel(scenList)
    s = scenList{si};
    u = R.(s).step;                 % T x 14
    E = R.(s).E;                    % T x 2  [E_BH E_BD]
    V = R.(s).V;                    % T x 1  tank level

    % ---- energy metrics ----
    pvTot  = sum(u(:,1:6),2);                       % = Ppv (PV balance)
    curt   = sum(u(:,6))*dt;                        % kWh curtailed
    curtSh = curt/(sum(pvTot)*dt + eps);            % share of available PV
    llp    = sum(u(:,13) > 1e-6)/T;                 % critical-path LPSP (eps slack)

    % ---- hydraulic metrics ----
    pumpEnergy  = sum(u(:,4) + u(:,8))*dt;          % kWh to pump (pvPump + PbatPump)
    purEnergy   = sum(u(:,5))*dt;                   % kWh to purifier
    waterPumped = p.kq*dt*sum(u(:,9));              % m^3 pumped (xTot)
    waterPurif  = p.kpur*dt*sum(u(:,5));            % m^3 purified
    waterDemand = dt*sum(pr.Dwat(1:T));             % m^3 demanded
    waterSlack  = dt*sum(u(:,14));                  % m^3 unmet (ws slack)
    V0 = 0.5*p.Vmax;
    Vf = V(end);
    % closure: demand = pumped + purified + unmet + drawdown
    waterResid = waterDemand - waterPumped - waterPurif - waterSlack - (V0 - Vf);

    % ---- diesel and duty ----
    diesKWh   = dt*sum(u(:,10));                    % kWh diesel dispatched
    diesCost  = p.cDiesel*diesKWh;                  % R$ (cDiesel assumed R$/kWh)
    pumpHours = dt*sum(u(:,11));                    % h, yPump
    pumpHoursDay = dt*sum(reshape(u(:,11), nDay, p.simDays), 1);   % 1 x simDays

    % ---- degradation / RUL (population-aware) ----
    % Energy equations charge PbatPump to B_D only when slicing is on.
    thrBH = dt*sum(u(:,2) + u(:,7));                % pvBH + PdisBH
    if any(bank.bus == 2)
        thrBD    = dt*sum(u(:,3) + u(:,8));         % pvBD + PbatPump
        sohLowBD = min(bank.soh(bank.bus == 2));
        popBD    = 'B_D';
    else
        thrBD    = dt*sum(u(:,2) + u(:,7) + u(:,8));% whole-bank throughput
        sohLowBD = min(bank.soh);
        popBD    = 'whole bank';
    end
    remPct = sohLowBD - EolSoH;                     % %-SoH remaining to EOL
    if thrBD > 1e-3
        duYr  = thrBD*p.kDeg*(8760/(T*dt));         % %-fade per year
        rulBD = remPct/duYr;                        % years to EOL
    else
        duYr  = 0;
        rulBD = Inf;                                % zero throughput -> '--'
    end

    % ---- solver diagnostics (guarded) ----
    if isfield(R.(s),'gap')
        g = R.(s).gap(~isnan(R.(s).gap));
    else
        g = [];
    end
    if isempty(g)
        gapMean = NaN; gapMax = NaN; nGap = 0;
    else
        gapMean = mean(g); gapMax = max(g); nGap = numel(g);
    end
    if isfield(R.(s),'exitg')
        ex = R.(s).exitg(~isnan(R.(s).exitg));
        nSolved = sum(ex == 1);
    else
        nSolved = NaN;
    end
    if isfield(R.(s),'Tmax')
        Tpeak = max(R.(s).Tmax);
    else
        Tpeak = NaN;
    end
    Tmargin = p.Tcrit - Tpeak;

    avgSolve = mean(R.(s).tSolve);
    maxSolve = max(R.(s).tSolve);
    wall     = R.(s).wall;
    overhead = wall - avgSolve*T;                   % thermal monitor + state bookkeeping

    metrics.(s) = struct('curtShare',curtSh,'curtEnergy',curt,'LLP',llp, ...
        'pumpEnergy',pumpEnergy,'purEnergy',purEnergy, ...
        'waterPumped',waterPumped,'waterPurif',waterPurif, ...
        'waterDemand',waterDemand,'waterSlack',waterSlack, ...
        'waterResid',waterResid,'V0',V0,'Vf',Vf, ...
        'thrBH',thrBH,'thrBD',thrBD,'sohLowBD',sohLowBD,'popBD',popBD, ...
        'duYr',duYr,'RUL_BD_yr',rulBD, ...
        'diesKWh',diesKWh,'diesCost',diesCost, ...
        'pumpHours',pumpHours,'pumpHoursDay',pumpHoursDay, ...
        'avgSolve',avgSolve,'maxSolve',maxSolve,'wall',wall,'overhead',overhead, ...
        'gapMean',gapMean,'gapMax',gapMax,'nGap',nGap,'nSolved',nSolved, ...
        'Tpeak',Tpeak,'Tmargin',Tmargin, ...
        'totalMILP',T,'nIsoEvents',R.(s).nIsoEvents);
end

save('results.mat','-append','metrics');

% ---- console summary ----
fprintf('\n===== MR-BEMS metrics =====\n');
fprintf('%-4s %8s %8s %10s %10s %8s %8s %10s\n', ...
    'Scen','Curt%','LLP%','Pump m3','Purif m3','RUL yr','Dies kWh','Wall s');
for si = 1:numel(scenList)
    s = scenList{si}; m = metrics.(s);
    if isfinite(m.RUL_BD_yr), rs = sprintf('%.1f', m.RUL_BD_yr); else, rs = '--'; end
    fprintf('%-4s %8.2f %8.3f %10.2f %10.3f %8s %8.2f %10.1f\n', ...
        s, m.curtShare*100, m.LLP*100, m.waterPumped, m.waterPurif, ...
        rs, m.diesKWh, m.wall);
end
fprintf('\n--- solver diagnostics ---\n');
for si = 1:numel(scenList)
    s = scenList{si}; m = metrics.(s);
    fprintf(['%-4s gap mean %.3e max %.3e (%d/%d recorded) | ' ...
             'exitflag==1: %s/%d | Tpeak %s C (margin %s) | overhead %.1f s | closure %+.3f m3\n'], ...
        s, m.gapMean, m.gapMax, m.nGap, m.totalMILP, ...
        num2str(m.nSolved), m.totalMILP, ...
        num2str(m.Tpeak,'%.2f'), num2str(m.Tmargin,'%.2f'), ...
        m.overhead, m.waterResid);
end
if all(ismember({'S1','S4'}, scenList)) && isfinite(metrics.S2.RUL_BD_yr)
    fprintf('\nRUL (B_D only, S2): %.1f yr | S4: -- (zero B_D throughput)\n', ...
        metrics.S2.RUL_BD_yr);
end
fprintf('Pumping duty (h/day): ');
for si = 1:numel(scenList)
    s = scenList{si};
    fprintf('%s=[%s] ', s, num2str(metrics.(s).pumpHoursDay,'%.2f '));
end
fprintf('\n');

% ---- Table 1: energy / water / RUL ----
fid = fopen('results_metrics.tex','w');
fprintf(fid,'%% generated by make_metrics_figs.m — do not hand-edit\n');
fprintf(fid,'%% RUL populations: S1,S3 = whole bank (no B_D); S2 = B_D only; S4 = zero B_D throughput\n');
fprintf(fid,['Scenario & Curt. (\\%%) & LLP (\\%%) & Water pump. (m^3) & ' ...
             'Water purif. (m^3) & Water unmet (m^3) & RUL B_D (yr) & Iso. events \\\\ \\hline\n']);
for si = 1:numel(scenList)
    s = scenList{si}; m = metrics.(s);
    if isfinite(m.RUL_BD_yr)
        rulStr = sprintf('%.1f', m.RUL_BD_yr);
    else
        rulStr = '--';
    end
    fprintf(fid,'%s & %.2f & %.3f & %.2f & %.2f & %.3f & %s & %d \\\\\n', ...
        s, m.curtShare*100, m.LLP*100, m.waterPumped, m.waterPurif, ...
        m.waterSlack, rulStr, m.nIsoEvents);
end
fclose(fid);

% ---- Table 2: computational performance ----
fid = fopen('results_computational.tex','w');
fprintf(fid,'%% generated by make_metrics_figs.m — do not hand-edit\n');
fprintf(fid,['Scenario & MILP solves & Avg. solve (s) & Max solve (s) & ' ...
             'Wall time (s) & Dispatch overhead (s) \\\\ \\hline\n']);
for si = 1:numel(scenList)
    s = scenList{si}; m = metrics.(s);
    fprintf(fid,'%s & %d & %.3f & %.3f & %.1f & %.1f \\\\\n', ...
        s, m.totalMILP, m.avgSolve, m.maxSolve, m.wall, m.overhead);
end
fclose(fid);

% ---- Table 3: diagnostics ----
fid = fopen('results_diagnostics.tex','w');
fprintf(fid,'%% generated by make_metrics_figs.m — do not hand-edit\n');
fprintf(fid,['Scenario & Gap mean & Gap max & Solved/672 & Diesel (kWh) & Diesel (R\\$) & ' ...
             'Pump duty (h) & Peak T (\\textdegree C) & Margin to 45 (\\textdegree C) & ' ...
             'Closure residual (m^3) \\\\ \\hline\n']);
for si = 1:numel(scenList)
    s = scenList{si}; m = metrics.(s);
    fprintf(fid,'%s & %.2e & %.2e & %s & %.2f & %.2f & %.2f & %.2f & %.2f & %+.3f \\\\\n', ...
        s, m.gapMean, m.gapMax, num2str(m.nSolved), m.diesKWh, m.diesCost, ...
        m.pumpHours, m.Tpeak, m.Tmargin, m.waterResid);
end
fclose(fid);

% ---- Figures ----
ix = 1:nDay;
t = pr.th(ix).';

% per-scenario figures
for si = 1:numel(scenList)
    s = scenList{si};
    f = figure('Color','w','Position',[100 100 820 640]);
    tl = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
    a1 = nexttile; a2 = nexttile; a3 = nexttile;
    plotScenario(a1, a2, a3, s);
    title(tl, sprintf('Representative day (%s)', s));
    exportgraphics(f, sprintf('fig_representative_day_%s.pdf', s), 'ContentType','vector');
    exportgraphics(f, sprintf('fig_representative_day_%s.png', s), 'Resolution',300);
    close(f);
end

% composite figure: one row per scenario
fc = figure('Color','w','Position',[60 60 1300 1250]);
tlc = tiledlayout(numel(scenList),3,'TileSpacing','compact','Padding','compact');
for si = 1:numel(scenList)
    s = scenList{si};
    a1 = nexttile; a2 = nexttile; a3 = nexttile;
    plotScenario(a1, a2, a3, s);
    title(a1, sprintf('%s — %s', s, scenLabel(s)));
end
title(tlc, 'Representative day — all scenarios');
exportgraphics(fc, 'fig_scenarios_composite.pdf', 'ContentType','vector');
exportgraphics(fc, 'fig_scenarios_composite.png', 'Resolution',300);
close(fc);

fprintf('\nWrote: results_metrics.tex, results_computational.tex, results_diagnostics.tex\n');
fprintf('Exported figures for scenarios: %s\n', strjoin(scenList, ', '));

% ======================================================================
    function plotScenario(axP, axS, axT, s)
        u = R.(s).step; E = R.(s).E; V = R.(s).V;
        socBH = E(ix,1) / R.(s).capBH0;
        if R.(s).capBD0 > 0
            socBD = E(ix,2) / R.(s).capBD0;
        else
            socBD = nan(nDay,1);
        end

        % Panel 1: power flows (fixed legend order in all scenarios)
        axes(axP); cla(axP); hold(axP,'on'); grid(axP,'on');
        Mflow = [u(ix,1) u(ix,2) (u(ix,4)+u(ix,5)) u(ix,6) u(ix,10)];
        area(axP, t, Mflow);
        cmap = [0.75 0.75 0.75   % PV -> critical load
                0.25 0.55 0.85   % PV -> B_H
                0.35 0.75 0.55   % PV -> pump/purifier
                0.90 0.40 0.30   % curtailment
                0.15 0.15 0.15]; % diesel
        colormap(axP, cmap);
        plot(axP, t, u(ix,7), 'b-', 'LineWidth', 1.5);
        plot(axP, t, pr.Pcrit(ix), 'k--', 'LineWidth', 1.2);
        legend(axP, {'PV->crit','PV->B_H','PV->pump/purif.','curtail.','diesel', ...
                     'Pdis,BH','Pcrit'}, 'Location','northwest','FontSize',8);
        xlim(axP, [t(1) t(end)]);
        ylabel(axP, 'kW');

        % Panel 2: storage trajectories
        axes(axS); cla(axS); hold(axS,'on'); grid(axS,'on');
        h1 = plot(axS, t, socBH*100, 'b', 'LineWidth', 1.5);
        if R.(s).capBD0 > 0
            h2 = plot(axS, t, socBD*100, 'r', 'LineWidth', 1.5);
        else
            h2 = plot(axS, nan, nan, 'r', 'LineWidth', 1.5);
        end
        h3 = plot(axS, t, V(ix)/p.Vmax*100, 'g', 'LineWidth', 1.5);
        yline(axS, p.SOCstar*100, 'b--');
        ylim(axS, [0 105]);
        xlim(axS, [t(1) t(end)]);
        legend(axS, [h1 h2 h3], {'SOC B_H','SOC B_D','Tank level'}, ...
            'Location','northwest','FontSize',8);
        ylabel(axS, '%');

        % Panel 3: operating-state sequence
        axes(axT); cla(axT); hold(axT,'on'); grid(axT,'on');
        stairs(axT, t, R.(s).state(ix), 'k', 'LineWidth', 1.5);
        ylim(axT, [0.5 6.5]);
        xlim(axT, [t(1) t(end)]);
        yticks(axT, 1:6); yticklabels(axT, {'M1','M2','M3','M4','D','F'});
        ylabel(axT, 'State');
        xlabel(axT, 'Hour of day');
    end

    function lab = scenLabel(s)
        switch s
            case 'S1', lab = 'baseline';
            case 'S2', lab = 'slicing';
            case 'S3', lab = 'nexus';
            case 'S4', lab = 'slicing + nexus';
            otherwise, lab = '';
        end
    end
end