#!/usr/bin/env julia

#
#  This is the main file for data assimilation runs.
#
#
# 1. loads up a configuration file,
# 2. obtains data from a WRF model,
# 3. construct covariate vectors
# 3. reads in observations and metadata for a list of stations,
# 4. runs the moisture model and the assimilation mechanism.
#
#

using Calendar
import Calendar.CalendarTime

using Storage
import Storage.setup_tag, Storage.spush, Storage.next_frame, Storage.flush_frame

using Stations
import Stations.Station, Stations.Observation, Stations.load_station_info,
       Stations.load_station_data, Stations.build_observation_data, Stations.register_to_grid, Stations.nearest_grid_point, Stations.obs_value, Stations.obs_station_id

using Kriging
import Kriging.trend_surface_model_kriging

using NetCDF
using WRF

using FM
import FM.FMModel, FM.advance_model, FM.kalman_update

function create_fm_variables(file_name)

    # first extract the dimensions
    nc = NetCDF.open(file_name)
    we_dim = nc.dim["west_east"]
    sn_dim = nc.dim["south_north"]
    t_dim = nc.dim["Time"]
    NetCDF.close(nc)

    var_names = ASCIIString[ "FM1", "FM10", "FM100" ]
    long_names = ["1hr fuel moisture", "10hr fuel moisture", "100hr fuel moisture"]
    for i in 1:3
        if !haskey(nc.vars, var_names[i])
            atts = {"coordinates"=>"XLONG XLAT","units"=>"kg/kg","stagger"=>"","MemoryOrder"=>"XY ","description"=>long_names[i]}
            NetCDF.nccreate(file_name, var_names[i], atts, we_dim, sn_dim, t_dim)
            println("INFO: created variable $(var_names[i])")
        else
            println("INFO: variable $(var_names[i]) already existed")
        end
    end
end



function main(args)

    # the arguments passed to the julia program do not include program name
    if length(args) != 1
        println("Usage: julia run_data_assimilation.jl cfg_file")
        exit(1)
    end

    t1 = Calendar.now()
    println("INFO: run_data_assimilation.jl started on $t1")
    
    ### Read configuration file and setup the system
    println("INFO: reading in config file $(args[1])")
    cfg = evalfile(args[1])

    # create the output directory if it does not exist
    println("INFO: output directory is ", cfg["output_dir"])
    !ispath(cfg["output_dir"]) && mkdir(cfg["output_dir"])

    # configure Storage mechanism
    Storage.sopen(cfg["output_dir"], "moisture_model_v2_diagnostics.txt", "frame")

    # setup Storage & output policies for interesting quantities
    setup_tag("mt", true, true)

    setup_tag("fm1_model_state_assim", false, false)
    setup_tag("fm1_model_var", false, false)
    setup_tag("fm10_model_state", false, false)
    setup_tag("fm10_model_state_assim", false, false)
    setup_tag("fm10_model_var", false, false)
    setup_tag("fm100_model_state_assim", false, false)
    setup_tag("fm100_model_var", false, false)

    setup_tag("fm10_model_na_state", false, false)
    setup_tag("fm10_model_deltas", false, false)

    setup_tag("kriging_beta", true, true)
    setup_tag("kriging_xtx_cond", false, true)
    setup_tag("kriging_field", false, false)
    setup_tag("kriging_variance", false, false)
    setup_tag("kriging_sigma2_eta", true, true)
    setup_tag("kriging_iters", false, true)
    setup_tag("kriging_subzero_s2_estimates", false, true)
    setup_tag("model_raws_mae", false, true)
    setup_tag("model_raws_mae_assim", false, true)
    setup_tag("model_na_raws_mae", false, true)

    # co-located model/model_na/kriging field/observation
    setup_tag("kriging_obs", false, false)
    setup_tag("kriging_obs_station_ids", false, false)
    setup_tag("kriging_obs_ngp", false, false)
    setup_tag("kriging_errors", true, true)

    setup_tag("kalman_gain_fm10", false, false)

    ### Load WRF output data
    t1 = Calendar.now()
    println("INFO: configuration complete, loading WRF data.")

    # read in data from the WRF output file pointed to by cfg
    w = WRF.load_wrf_data(cfg["wrf_output"], ["HGT"])
 
    # the terrain height need not be stored for all time points
    WRF.slice_field(w, "HGT")

    # extract WRF fields
    lat, lon = WRF.lat(w), WRF.lon(w) 
    dsize = size(lat)
    wtm = WRF.times(w)
    println("INFO: WRF grid size is $(dsize[1]) x $(dsize[2]) and found $(length(wtm)) timepoints.")

    # retrieve equilibria and rain (these are already precomputed)
    Ed, Ew = WRF.field(w, "Ed"), WRF.field(w, "Ew")
    rain = WRF.field(w, "RAIN")
    hgt = WRF.field(w, "HGT")
    T = WRF.interpolated_field(w, "T2")
    P = WRF.interpolated_field(w, "PSFC")

    t2 = Calendar.now()
    println("INFO: WRF output loaded, sliced and diced [$(t2-t1)].")

    ### Load observation data from stations
    io = open(join([cfg["station_info_dir"], cfg["station_info"]], "/"), "r")
    station_ids = filter(x -> x[1] != '#', map(x -> strip(x), readlines(io)))
    close(io)

    # load each station from its info and observation files
    stations = Station[]
    for sid in station_ids
        s = load_station_info(join([cfg["station_info_dir"], string(sid, ".info")], "/"))
        load_station_data(s, join([cfg["station_data_dir"], string(sid, ".obs")], "/"))
	register_to_grid(s, lat, lon)
#        println("STATION: $(s.id), $(s.loc), ngp is $(s.ngp) with lat $(lat[s.ngp[1], s.ngp[2]]) and lon $(lon[s.ngp[1], s.ngp[2]]).")
        push!(stations, s)
    end

    # build the observation data from stations
    obs_fm10 = build_observation_data(stations, "FM")
    obs_times = keys(obs_fm10)

    t3 = Calendar.now()
    println("INFO: Station data loaded and preprocessed [$(t3 - t2)].")

    ### Initialize model

    # number of simulated fuel components
    Nf = 3

    # construct initial conditions (FIXME: can we do better here?)
    E = squeeze(0.5 * (Ed[:,:,2] + Ew[:,:,2]), 3)

    # set up parameters
    Q = diagm(cfg["Q"])
    P0 = diagm(cfg["P0"])
    mV = zeros(Float64, dsize)
    pred = zeros(Float64, dsize)
    mresV = zeros(Float64, dsize)
    mid = zeros(Int32, dsize)
    Kg = zeros(Float64, (dsize[1], dsize[2], 9))
    K = zeros(Float64, dsize)
    V = zeros(Float64, dsize)

    # prepare static & time-varying covariates
    cov_ids = cfg["covariates"]
    st_covar_map = [:lon => lon,
                    :lat => lat,
                    :elevation => hgt,
                    :constant => ones(Float64, dsize) ]
    dyn_covar_map = [:temperature => T, :pressure => P, :rain => rain]
    Xd3 = length(cov_ids) + 1
    X = zeros(Float64, (dsize[1], dsize[2], Xd3))
    Xr = zeros(Float64, (dsize[1], dsize[2], Xd3))
    for i in 2:Xd3
        cov_id = cov_ids[i-1]
        if haskey(st_covar_map, cov_id)
            println("INFO: processing static covariate $cov_id.")
            v = st_covar_map[cov_id]
            Xr[:,:,i] = v
        elseif haskey(dyn_covar_map, cov_id)
            println("INFO: found dynamic covariate $(cov_id).")
        else
            error("ERROR: unknown covariate $(cov_id) encountered, fatal.")
        end
    end
    println("INFO: there are $Xd3 covariates (including model state).")

    t1 = Calendar.now()
    println("INFO: starting simulation at $t1 ...") 
    dt = (wtm[2] - wtm[1]).millis / 1000
    assim_time_win = cfg["assimilation_time_window"]
    println("INFO: time step from WRF is $dt s, assimilation time window is $assim_time_win s.")

    # construct model grid from fuel parameters
    Tk = [ 1.0, 10.0, 100.0 ]
    models = Array(FMModel, dsize)
    models_na = Array(FMModel, dsize)
    for i in 1:dsize[1]
    	for j in 1:dsize[2]
            geo_loc = (lat[i,j], lon[i,j])
	    models[i,j] = FMModel(geo_loc, Nf, E[i,j], P0, Tk)
	    models_na[i,j] = FMModel(geo_loc, Nf, E[i,j], P0, Tk)
	end
    end

    # create the new variables in the wrfout file for storing fuel moisture
    println("INFO: creating FM variables in wrfout file")
    create_fm_variables(cfg["wrf_output"])
    nc = NetCDF.open(cfg["wrf_output"], NetCDF.NC_WRITE)

    ###  Run the model and data assimilation
    for t in 2:length(wtm)
    	mt = wtm[t]
        spush("mt", mt)

        # run the model update (in parallel if possible)
	for i in 1:dsize[1]
	    for j in 1:dsize[2]
	        advance_model(models[i,j], Ed[i, j, t-1], Ew[i, j, t-1], rain[i, j, t-1], dt, Q)
		advance_model(models_na[i,j], Ed[i, j, t-1], Ew[i, j, t-1], rain[i, j, t-1], dt, Q)
	    end
	end

        # store the model state in an array (and store in output frame)
        fm10_model_state = [ models[i,j].m_ext[2] for i=1:dsize[1], j=1:dsize[2] ]
        fm10_model_na_state = [ models_na[i,j].m_ext[2] for i=1:dsize[1], j=1:dsize[2] ]
        fm10_model_var = [ models[i,j].P[2,2] for i=1:dsize[1], j=1:dsize[2] ]

        spush("fm10_model_state", fm10_model_state)
        spush("fm10_model_na_state", fm10_model_na_state)
        spush("fm10_model_var", fm10_model_var)

        # if observation data for this timepoint is available
        obs_i = Observation[]
        tm_valid_now = filter(x -> abs((mt - x).millis) / 1000.0 <= assim_time_win/2, obs_times)

        # gather all observations
        for tvn in tm_valid_now append!(obs_i, obs_fm10[tvn]) end

        # exclude zero observations - must be sensor failure
        obs_i = filter(x -> obs_value(x) > 0, obs_i)

        # if there are no valid observations, continue with next time step, else run kriging
        if length(obs_i) > 0

            # set the current fm10 model state as the covariate
            X[:,:,1] = fm10_model_state

#            fm10_norm = sum(fm10_model_state.^2)^0.5
            println("INFO: assimilating $(length(obs_i)) observations.")

            # loop over additional covariates
            for i in 2:Xd3
                cov_id = cov_ids[i-1]
                if haskey(st_covar_map, cov_id)
                    # just copy and rescale corresponding static covariate
                    X[:,:,i] = Xr[:,:,i]
                elseif haskey(dyn_covar_map, cov_id)
                    # retrieve the field pointed to by the dynamic covariate id
                    F = dyn_covar_map[cov_id]
                    X[:,:,i] = squeeze(F[:,:,t], 3)
                else
                    error("FATAL: found unknown covariate.")
                end
            end

            # store diagnostic information
            ngp_list = map(x -> nearest_grid_point(x), obs_i)
            stat_ids = map(x -> obs_station_id(x), obs_i)
            m_at_obs = Float64[X[i, j, 1] for (i,j) in  ngp_list]
            m_na_at_obs = Float64[models_na[i,j].m_ext[2] for (i,j) in ngp_list]
            raws = Float64[obs_value(o) for o in obs_i]

            spush("model_raws_mae", mean(abs(m_at_obs - raws)))
            spush("model_na_raws_mae", mean(abs(m_na_at_obs - raws)))

            spush("kriging_obs", raws)
            spush("kriging_obs_station_ids", stat_ids)
            spush("kriging_obs_ngp", ngp_list)

            # compute the kriging estimates and fill in pre-allocated arrays
            trend_surface_model_kriging(obs_i, X, K, V)

            # push diagnostic outputs
            spush("kriging_field", K)
            spush("kriging_variance", V)

            # execute the Kalman update at each grid point
            Kp = zeros(1)
            Vp = zeros(1,1)
            Kg = zeros(Float64, dsize)
            fuel_types = [2]
            for i in 1:dsize[1]
                for j in 1:dsize[2]
                    Kp[1] = K[i,j]
                    Vp[1,1] = V[i,j]
                    Kg[i,j] = kalman_update(models[i,j], Kp, Vp, fuel_types)[1,1]
                end
            end

            # push the fm10 model state after the assimilation
            fm10_model_state = [ models[i,j].m_ext[2] for i=1:dsize[1], j=1:dsize[2] ]
            spush("fm10_model_state_assim", fm10_model_state)

            # retrieve adjustments to time constants and to equilibria
            fm10_adj = zeros(Float64, (6, dsize[1], dsize[2]))
            for i in 1:dsize[1]
                for j in 1:dsize[2]
                    fm10_adj[:,i,j] = models[i,j].m_ext[Nf+1:2*Nf+3]
                end
            end
            fm10_adj_max = [ max(abs(fm10_adj[i,:,:])) for i in 1:6 ]
            spush("fm10_model_deltas", fm10_adj_max)

            # gather model values at ngp points after assimilation
            m_at_obs = Float64[fm10_model_state[i, j] for (i,j) in  ngp_list]
            spush("model_raws_mae_assim", mean(abs(m_at_obs - raws)))

            spush("kalman_gain_fm10", Kg)

            # move to the next storage frame
            next_frame()

        end # if there is anything to assimilate

        # store current assimilated state in the wrfout file
        fm_stor = zeros(Float64, (dsize[1], dsize[2], 1))
        fm_stor[:,:,1] = [ models[i,j].m_ext[1] for i=1:dsize[1], j=1:dsize[2] ]
        NetCDF.putvar(nc, "FM1", [1, 1, t], fm_stor)
        fm_stor[:,:,1] = [ models[i,j].m_ext[2] for i=1:dsize[1], j=1:dsize[2] ]
        NetCDF.putvar(nc, "FM10", [1, 1, t], fm_stor)
        fm_stor[:,:,1] = [ models[i,j].m_ext[3] for i=1:dsize[1], j=1:dsize[2] ]
        NetCDF.putvar(nc, "FM100", [1, 1, t], fm_stor)

    end # for each time point

    # Close down the storage system
    Storage.sclose()

    NetCDF.close(nc)

    t2 = Calendar.now()
    println("INFO: simulation completed at $t2 after $(t2-t1).")

end


main(ARGS)
