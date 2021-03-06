if ~exist('initialized', 'var')
    addpath('C:\CODE\MariusBox\Primitives\')
    rng(1);
    
    Nfilt 	= ops.Nfilt; %256+128;
    nt0 	= 61;
    ntbuff  = ops.ntbuff;
    NT  	= ops.NT;

    Nrank   = ops.Nrank;
    Th 		= ops.Th;
    maxFR 	= ops.maxFR;
    
    Nchan 	= ops.Nchan;
    
    batchstart = 0:NT:NT*(Nbatch-Nbatch_buff);
    
    delta = NaN * ones(Nbatch, 1);
    iperm = randperm(Nbatch);
      gpuDevice(1);   
  
    switch ops.initialize
        case 'fromData'
            dWU = WUinit(:,:,1:Nfilt);
%             dWU = alignWU(dWU);
        otherwise
            initialize_waves0;
            ipck = randperm(size(Winit,2), Nfilt);
            W = [];
            U = [];
            for i = 1:Nrank
                W = cat(3, W, Winit(:, ipck)/Nrank);
                U = cat(3, U, Uinit(:, ipck));
            end
            W = alignW(W);
            
            dWU = zeros(nt0, Nchan, Nfilt, 'single');
            for k = 1:Nfilt
                wu = squeeze(W(:,k,:)) * squeeze(U(:,k,:))';
                newnorm = sum(wu(:).^2).^.5;
                W(:,k,:) = W(:,k,:)/newnorm;
                
                dWU(:,:,k) = 10 * wu;
            end           
            WUinit = dWU;
    end
    [W, U, mu, UtU, nu] = decompose_dWU(dWU, Nrank);    
    
    nspikes = zeros(Nfilt, Nbatch);
    lam =  ones(Nfilt, 1, 'single');
    
    freqUpdate =  ceil(250 / (ops.NT/ops.fs));
    iUpdate = 1:freqUpdate:Nbatch;
    
    dbins = zeros(100, Nfilt);
    dsum = 0;
    miniorder = repmat(iperm, 1, ops.nfullpasses);
%     miniorder = repmat([1:Nbatch Nbatch:-1:1], 1, ops.nfullpasses/2);    

    i = 1;
    
    epu = ops.epu;
    initialized = 1;
    
end


%%
pmi = exp(-1./linspace(1/ops.momentum(1), 1/ops.momentum(2), Nbatch*ops.nannealpasses));

% pmi  = linspace(exp(-ops.momentum(1)), exp(-ops.momentum(2)), Nbatch*ops.nannealpasses);

Thi  = linspace(ops.Th(1),                 ops.Th(2), Nbatch*ops.nannealpasses);
if ops.lam(1)==0
    lami = linspace(ops.lam(1), ops.lam(2), Nbatch*ops.nannealpasses); 
else
    lami = exp(linspace(log(ops.lam(1)), log(ops.lam(2)), Nbatch*ops.nannealpasses));
end
 
if Nbatch_buff<Nbatch
    fid = fopen(fullfile(root, fnameTW), 'r');
end

st3 = [];

iup = 0;

nUpdate = 0;
nswitch = [0];
msg = [];
fprintf('Time %3.0fs. Optimizing templates ...\n', toc)
while (i<=Nbatch * ops.nfullpasses+1)    
    % set the annealing parameters
    if i<Nbatch*ops.nannealpasses
        Th      = Thi(i);
        lam(:)  = lami(i);
        pm      = pmi(i);
    end
    
    % some of the parameters change with iteration number
    Params = double([NT Nfilt Th maxFR 10 Nchan Nrank pm epu]);    
    
    % update the parameters every freqUpdate iterations
    if i>1 &&  ismember(rem(i,Nbatch), iUpdate) %&& i>Nbatch        
        dWU = gather(dWU);
        nUpdate = nUpdate + 1;
        % break bimodal clusters and remove low variance clusters
        if  ops.shuffle_clusters &&...
                i>Nbatch && nUpdate>=5 && i<Nbatch*ops.nannealpasses
            % every 5 updates do a split/merge
            nUpdate = 0;
           [dWU, dbins, nswitch, nspikes, iswitch] = ...
               replace_clusters(dWU, dbins,  Nbatch, ops.mergeT, ops.splitT, WUinit, nspikes);      
        end
        
        dWU = alignWU(dWU);
       
        % parameter update    
        iup = iup + 1;
        Wr(:,:,:,iup) = W;
        Ur(:,:,:,iup) = U;
        mur(:,iup) = mu;
        [W, U, mu, UtU, nu] = decompose_dWU(dWU, Nrank);

        
        dWU = gpuArray(dWU);
        
        clf
        NSP = sum(nspikes,2);
        if ops.showfigures
            for j = 1:10:Nfilt
                if j+9>Nfilt;
                    j = Nfilt -9;
                end
                plot(log(1+NSP(j + [0:1:9])), mu(j+ [0:1:9]), 'o');
                xlabel('log of number of spikes')
                ylabel('amplitude of template')
                hold all
            end
            axis tight;
            title(sprintf('%d  ', nswitch)); drawnow;
        end
        % break if last iteration reached
        if i>Nbatch * ops.nfullpasses; break; end
        
        % record the error function for this iteration
        rez.errall(ceil(i/freqUpdate))          = nanmean(delta);
        
    end

    % select batch and load from RAM or disk
    ibatch = miniorder(i);
    if ibatch>Nbatch_buff
        offset = 2 * ops.Nchan*batchstart(ibatch-Nbatch_buff);
        fseek(fid, offset, 'bof');
        dat = fread(fid, [NT ops.Nchan], '*int16');
    else
       dat = DATA(:,:,ibatch); 
    end
    
    % move data to GPU and scale it
    dataRAW = gpuArray(dat);
    dataRAW = single(dataRAW);
    dataRAW = dataRAW / ops.scaleproc;
    
    % project data in low-dim space 
    data = dataRAW * U(:,:);
    
    % run GPU code to get spike times and coefficients
    [dWU, st, id, x,Cost, nsp] = ...
        mexMPregMU(Params,dataRAW,W,data,UtU,mu, lam .* (20./mu).^2, dWU, nu);
    
    % compute numbers of spikes
    nsp                = gather(nsp(:));
    nspikes(:, ibatch) = nsp;
    
    % bin the amplitudes of the spikes
    xround = min(max(1, round(int32(x))), 100);
    
    % this is a hard-coded forgetting factor, needs to become an option
    dbins = .9975 * dbins;
    dbins(xround + id * size(dbins,1)) = dbins(xround + id * size(dbins,1)) + 1;
    
    % estimate cost function at this time step
    delta(ibatch) = sum(Cost)/1e6;
    
    % update status
    if rem(i,100)==1
        nsort = sort(round(sum(nspikes,2)), 'descend');
        fprintf(repmat('\b', 1, numel(msg)));
        msg = sprintf('Time %2.2f, batch %d/%d, mu %2.2f, neg-err %2.6f, NTOT %d, n100 %d, n200 %d, n300 %d, n400 %d\n', ...
            toc, i,Nbatch* ops.nfullpasses,nanmedian(mu(:)), nanmean(delta), round(sum(nsort)), ...
            nsort(min(size(W,2), 100)), nsort(min(size(W,2), 200)), ...
                nsort(min(size(W,2), 300)), nsort(min(size(W,2), 400)));
        fprintf(msg);        
    end
    
    % increase iteration counter
    i = i+1;
end

% close the data file if it has been used
if Nbatch_buff<Nbatch
    fclose(fid);
end


%%

% [dWU, dbins, nswitch, nspikes, iswitch] = ...
%     replace_clusters(dWU, dbins,  Nbatch, ops.mergeT, ops.splitT, WUinit, nspikes);
% % align except on last estimation
% dWU = alignWU(dWU);
% 
% % %% parameter update
% [dWU, W, U, mu, UtU] = decompose_dWU(dWU, Nrank);
