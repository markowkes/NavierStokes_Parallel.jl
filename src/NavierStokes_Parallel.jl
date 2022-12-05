module NavierStokes_Parallel

export run_solver, parameters, VFcircle, @unpack

using MPI
using UnPack
using OffsetArrays
using Plots
using Printf

include("Parameters.jl")
include("Mesh.jl")
include("Parallel.jl")
include("Tools.jl")
include("Velocity.jl")
include("Pressure.jl")
include("VF.jl")
include("VFgeom.jl")
include("ELVIRA.jl")
include("WriteData.jl")

function run_solver(param, IC!, BC!)
    @unpack stepMax,tFinal,solveNS = param

    println("Starting solver...")

    # Create parallel environment
    par_env = parallel_init(param)
    @unpack isroot = par_env

    # Create mesh
    mesh = create_mesh(param,par_env)
    @unpack imin_,imax_,jmin_,jmax_,kmin_,kmax_ = mesh

    # Create work arrays
    P,u,v,w,VF,nx,ny,nz,D,us,vs,ws,uf,vf,wf,tmp1,tmp2,tmp3 = initArrays(mesh)

    # Create initial condition
    t = 0.0
    IC!(P,u,v,w,VF,mesh)
    #printArray("VF",VF,par_env)

    # Apply boundary conditions
    BC!(u,v,w,mesh,par_env)

    # Update processor boundaries (overwrites BCs if periodic)
    update_borders!(u,mesh,par_env)
    update_borders!(v,mesh,par_env)
    update_borders!(w,mesh,par_env)
    update_borders!(VF,mesh,par_env)

    # Create face velocities
    interpolateFace!(u,v,w,uf,vf,wf,mesh)
    
    # Initialize VTK outputs
    pvd,pvd_PLIC = VTK_init(param,par_env)

    # Loop over time
    nstep = 0
    iter = 0
    while nstep<stepMax && t<tFinal

        # Update step counter
        nstep += 1

        # Compute timestep and update time
        dt = compute_dt(u,v,w,param,mesh,par_env)
        t += dt;

        if solveNS

            # Predictor step
            predictor!(us,vs,ws,u,v,w,uf,vf,wf,tmp1,tmp2,tmp3,dt,param,mesh,par_env)
            
            # Apply boundary conditions
            BC!(us,vs,ws,mesh,par_env)

            # Update Processor boundaries (overwrites BCs if periodic)
            update_borders!(us,mesh,par_env)
            update_borders!(vs,mesh,par_env)
            update_borders!(ws,mesh,par_env)
            
            # Create face velocities
            interpolateFace!(us,vs,ws,uf,vf,wf,mesh)
            
            # Call pressure Solver (handles processor boundaries for P)
            iter = pressure_solver!(P,uf,vf,wf,dt,param,mesh,par_env)

            # Corrector face velocities
            corrector!(uf,vf,wf,P,dt,param,mesh)

            # Interpolate velocity to cell centers (keeping BCs from predictor)
            interpolateCenter!(u,v,w,us,vs,ws,uf,vf,wf,mesh)

            # Update Processor boundaries
            update_borders!(u,mesh,par_env)
            update_borders!(v,mesh,par_env)
            update_borders!(w,mesh,par_env)

        end

        # Transport VF
        VF_transport!(VF,nx,ny,nz,D,u,v,w,uf,vf,wf,tmp1,tmp2,tmp3,t,dt,param,mesh,par_env)
        
        # Check divergence
        divg = divergence(uf,vf,wf,mesh,par_env)
        
        # Output
        std_out(nstep,t,P,u,v,w,divg,iter,par_env)
        VTK(nstep,t,P,u,v,w,VF,nx,ny,nz,D,divg,tmp1,param,mesh,par_env,pvd,pvd_PLIC)

    end

    # Finalize
    #VTK_finalize(pvd) (called in VTK)
    #parallel_finalize()

end # run_solver

end
