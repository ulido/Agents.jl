## Basic data collection functions

get_data(a, s::Symbol) = getproperty(a, s)
get_data(a, f::Function) = f(a)

"""
    collect_agent_data(model::ABM, properties::AbstractArray, step::Int)

Collect agent properties into a dataframe. `properties` can have symbols (agent fields) or functions that take an agent as input.
"""
function collect_agent_data(model::ABM, properties::AbstractArray, step::Int)
  dd = DataFrame()
  dd[!, :id] = collect(keys(model.agents))
  for fn in properties
    dd[!, fn] = get_data.(values(model.agents), fn)
  end
  dd[!, :step] = fill(step, size(dd, 1))
  return dd
end

"""
    collect_model_data(model::ABM, properties::AbstractArray, step::Int)

Collect model properties from functions or symbols provided in `properties`.
"""
function collect_model_data(model::ABM, properties::AbstractArray, step::Int)
  dd = DataFrame()
  for fn in properties
    r =  get_data(model, fn)
    dd[!, Symbol(fn)] = [r]
  end
  dd[!, :step] = fill(step, size(dd, 1))
  return dd
end

"""
    aggregate_data(df::AbstractDataFrame, aggregation_dict::Dict)
  
Aggregate `df` columns  with some function(s) specified in `aggregation_dict`.
Each key in `aggregation_dict` is a column name (Symbol), and each value is
an array of function to aggregate that column.

Aggregation occurs per step.
"""
function aggregate_data(df::AbstractDataFrame, aggregation_dict::Dict)
  all_keys = collect(keys(aggregation_dict))
  dfnames = names(df)
  available_keys = [k for k in all_keys if in(k, dfnames)]
  length(available_keys) == 0 && return
  v1 = aggregation_dict[available_keys[1]]
  final_df = by(df, :step,  available_keys[1] => v1[1])
  for v2 in v1[2:end]
    dd = by(df, :step,  available_keys[1] => v2)
    final_df = join(final_df, dd, on=:step)
  end
  for k in available_keys[2:end]
    v = aggregation_dict[k]
    for v2 in v
      dd = by(df, :step,  k => v2)
      final_df = join(final_df, dd, on=:step)
    end
  end

  # rename columns
  colnames = Array{Symbol}(undef, size(final_df, 2)) 
  colnames[1] = :step
  counter = 2
  for k in available_keys
    v = aggregation_dict[k]
    for vv in v
      colnames[counter] = Symbol(join([vv,"(", string(k), ")"], ""))
      counter += 1
    end
  end
  rename!(final_df, colnames)

  return final_df
end

## step functions
###################

"used in _step!"
function _step_agent_collect!(df::DataFrame, model::ABM, agent_properties,  aggregation_dict, step::Int)
  if isnothing(aggregation_dict)
    dft = collect_agent_data(model, agent_properties, step)
    df = vcat(df, dft)
  else
    dfall = collect_agent_data(model, agent_properties, step)
    dfa = aggregate_data(dfall, aggregation_dict)
    df = vcat(df, dfa)
  end
  return df
end

"used in _step!"
function _step_model_collect!(df::DataFrame, model::ABM, model_properties,  aggregation_dict, step::Int)
  if isnothing(aggregation_dict)
    dft = collect_model_data(model, model_properties, step)
    df = vcat(df, dft)
  else
    dfall = collect_model_data(model, model_properties, step)
    dfa = aggregate_data(dfall, aggregation_dict)
    df = vcat(df, dfa)
  end
  return df
end

function _step!(model, agent_step!, model_step!, n::F, when; model_properties=nothing, aggregation_dict=nothing, agent_properties=nothing) where F<:Function
  df_agent = DataFrame()
  df_model = DataFrame()
  ss = 0
  while !n(model)
    step!(model, agent_step!, model_step!, 1)
    if ss in when
      if !isnothing(model_properties)
        df_model = _step_model_collect!(df_model, model, model_properties,  aggregation_dict, ss)
      end
      if !isnothing(agent_properties)
        df_agent = _step_agent_collect!(df_agent, model, agent_properties,  aggregation_dict, ss)
      end
    end
    ss += 1
  end
  return df_agent, df_model
end

function _step!(model, agent_step!, model_step!, n::Int, when;
  model_properties=nothing, aggregation_dict=nothing, agent_properties=nothing)
  df_agent = DataFrame()
  df_model = DataFrame()
  for ss in 1:n
    step!(model, agent_step!, model_step!, 1)
    if ss in when
      if !isnothing(model_properties)
        df_model = _step_model_collect!(df_model, model, model_properties,  aggregation_dict, ss)
      end
      if !isnothing(agent_properties)
        df_agent = _step_agent_collect!(df_agent, model, agent_properties,  aggregation_dict, ss)
      end
    end
  end
  return df_agent, df_model
end

"Run replicates of the same simulation"
function series_replicates(model, agent_step!, model_step!, n, when; 
  model_properties=nothing, aggregation_dict=nothing, agent_properties=nothing, replicates=1)

  dataall = _step!(deepcopy(model), agent_step!, model_step!, n, when, model_properties=model_properties, aggregation_dict=aggregation_dict, agent_properties=agent_properties)
  dataall[!, :replicate] = [1 for i in 1:size(dataall, 1)]

  for rep in 2:replicates
    data = _step!(deepcopy(model), agent_step!, model_step!, n, when, model_properties=model_properties, aggregation_dict=aggregation_dict, agent_properties=agent_properties)
    data[!, :replicate] = [rep for i in 1:size(data, 1)]

    dataall = vcat(dataall, data)
  end
  return dataall
end

"""
A function to be used in `pmap` in `parallel_replicates`. It runs the `step!` function, but has a `dummyvar` parameter that does nothing, but is required for the `pmap` function.
"""
function parallel_step_dummy!(model::ABM, agent_step!, model_step!, n, when;
   model_properties=nothing, aggregation_dict=nothing, agent_properties=nothing, dummyvar=0)
  data = _step!(deepcopy(model), agent_step!, model_step!, n, when, model_properties=model_properties, aggregation_dict=aggregation_dict, agent_properties=agent_properties)
  return data
end

"""
    parallel_replicates(agent_step!, model::ABM, n, agent_properties::Array{Symbol}, when::AbstractArray{Integer}, replicates::Integer)

Runs `replicates` number of simulations in parallel and returns a `DataFrame`.
"""
function parallel_replicates(model::ABM, agent_step!, model_step!, n, when;
  model_properties=nothing, aggregation_dict=nothing, agent_properties=nothing, replicates=1)

  all_data = pmap(j-> parallel_step_dummy!(model, agent_step!, model_step!, n, when;
   model_properties=model_properties, aggregation_dict=aggregation_dict, agent_properties=agent_positions, dummyvar=j), 1:replicates)

  dd = DataFrame()
  for (rep, d) in enumerate(all_data)
    d[!, :replicate] = [rep for i in 1:size(d, 1)]
    dd = vcat(dd, d)
  end

  return dd
end


"""
    paramscan(parameters, initialize; kwargs...)

Run the model with all the parameter value combinations given in `parameters`,
while initializing the model with `initialize`.
This function uses `DrWatson`'s [`dict_list`](https://juliadynamics.github.io/DrWatson.jl/dev/run&list/#DrWatson.dict_list)
internally. This means that every entry of `parameters` that is a `Vector`,
contains many parameters and thus is scanned. All other entries of
`parameters` that are not `Vector`s are not expanded in the scan.

`initialize` is a function that creates an ABM. It should accept keyword arguments.

### Keywords
All the following keywords are propagated into [`step!`](@ref):
`agent_step!, properties, n, when = 1:n, model_step! = dummystep`,
`step0::Bool = true`, `parallel::Bool = false`, `replicates::Int = 0`.

The following keywords modify the `paramscan` function:

`include_constants::Bool=false` determines whether constant parameters should be
included in the output `DataFrame`.

`progress::Bool = true` whether to show the progress of simulations.
"""
function paramscan(parameters::Dict, initialize;
  agent_step!, properties, n,
  when = 1:n,
  model_step! = dummystep,
  include_constants::Bool = false,
  replicates::Int = 0,
  progress::Bool = true,
  parallel::Bool = false
  )

  params = dict_list(parameters)
  if include_constants
    changing_params = keys(parameters)
  else
    changing_params = [k for (k, v) in parameters if typeof(v)<:Vector]
  end

  alldata = DataFrame()
  combs = dict_list(parameters)
  ncombs = length(combs)
  counter = 0
  for d in combs
    model = initialize(; d...)
    data = step!(model, agent_step!, model_step!, n, properties, when=when, replicates=replicates, parallel=parallel)  # TODO
    addparams!(data, d, changing_params)
    alldata = vcat(data, alldata)
    if progress
      # show progress
      counter += 1
      print("\u1b[1G")
      percent = round(counter*100/ncombs, digits=2)
      print("Progress: $percent%")
      print("\u1b[K")
    end
  end
  println()
  return alldata
end

"""
Adds new columns for each parameter in `changing_params`.
"""
function addparams!(df::AbstractDataFrame, params::Dict, changing_params)
  nrows = size(df, 1)
  for c in changing_params
    df[!, c] = [params[c] for i in 1:nrows]
  end
end

# This function is taken from DrWatson:
function dict_list(c::Dict)
    iterable_fields = filter(k -> typeof(c[k]) <: Vector, keys(c))
    non_iterables = setdiff(keys(c), iterable_fields)

    iterable_dict = Dict(iterable_fields .=> getindex.(Ref(c), iterable_fields))
    non_iterable_dict = Dict(non_iterables .=> getindex.(Ref(c), non_iterables))

    vec(
        map(Iterators.product(values(iterable_dict)...)) do vals
            dd = Dict(keys(iterable_dict) .=> vals)
            if isempty(non_iterable_dict)
                dd
            elseif isempty(iterable_dict)
                non_iterable_dict
            else
                merge(non_iterable_dict, dd)
            end
        end
    )
end
