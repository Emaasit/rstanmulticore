#' Fit a model using Stan on multiple cores
#'
#' A wrapper for \code{rstan::stan} that, when possible, runs each MCMC chain on a
#' separate core. See \code{help(stan)} for details of the syntax. In the documentation below,
#' the stan help page is quoted without further attribution.
#'
#' \code{pstan} does all of the work of fitting a Stan model and returning the results as
#' an instance of \code{stanfit}. First, it translates the Stan model to C++ code.
#' Second, the C++ code is compiled into a binary shared object, which is loaded into
#' the current R session (an object of S4 class \code{stanmodel} is created).
#' Third, \code{pstan} calls \code{parallel::makeCluster} to setup a parallel worker
#' process for every chain (or the maximum number of cores, whichever is less), distributes
#' the compiled \code{stanmodel} to each worker, and uses
#' \code{parallel:parLapply} to execute \code{stan:rstan} on each core.
#' Finally, the chains are collected and wrapped into an object of S4 class \code{stanfit},
#' which provides functions such as print, summary, and plot to inspect and retrieve the
#' results of the fitted model.
#'
#' Note that \code{pstan} can also be used to sample again from a fitted model under
#' different settings (e.g., different \code{iter}) by providing argument fit. In this case,
#' the compiled C++ code for the model is reused.
#'
#' @param file A character string file name or a connection that R supports containing the text of a model specification in the Stan modeling language; a model may also be specified directly as a character string using parameter \code{model_code} or through a previous fit using parameter \code{fit}. When \code{fit} is specified, parameter \code{file} is ignored.
#' @param model_name A character string naming the model; defaults to \code{"anon_model"}. However, the model name would be derived from \code{file} or \code{model_code} (if \code{model_code} is the name of a character string object) if \code{model_name} is not specified.
#' @param model_code A character string either containing the model definition or the name of a character string object in the workspace. This parameter is used only if parameter \code{file} is not specified. When \code{fit} is specified, the model compiled previously is used so specifying \code{model_code} is ignored.
#' @param fit An instance of S4 class \code{stanfit} derived from a previous fit; defaults to \code{NA}. If fit is not \code{NA}, the compiled model associated with the fitted result is re-used; thus the time that would otherwise be spent recompiling the C++ code for the model can be saved.
#' @param data An object of class \code{list, environment} providing the data for the model, or a vector of character strings for all the names of objects used as data in the working space. See \code{help(stan)} for further details.
#' @param chains A positive integer specifying number of chains; defaults to 4. When possible, each chain is executed on its own core.
#' @param seed The seed, a positive integer, for random number generation of Stan. The default is generated from 1 to the maximum integer supported by R so fixing the seed of R's random number generator can essentially fix the seed of Stan. When multiple chains are used, only one seed is needed, with other chains' seeds being generated from the first chain's seed to prevent dependency among the random number streams for the chains. When a seed is specified by a number, as.integer will be applied to it. If as.integer produces NA, the seed is generated randomly. We can also specify a seed using a character string of digits, such as "12345", which is converted to integer.
#' @param pdebug If \code{TRUE}, \code{pstan} will create a file in the current working directory,
#' \code{stan-debug-*}, that contains the output of the \code{rstan::stan} calls. Defaults to \code{TRUE}.
#' @param ... The additional arguments are passed directly to \code{rstan::stan}. See \code{help(stan)} for documentation.
#' @return Fitted results as an object of S4 class \code{stanfit}. If error occurs before or during sampling, and if \code{test_grad = TRUE}, the returned object would not contain samples. But the compiled binary object for the model is still included, so we can reuse the returned object for another sampling.
#' @import rstan
#' @import parallel
#' @export
pstan <- function(file, model_name = "anon_model", model_code = "",
       fit = NULL, ## Changed from NA to NULL for easier detection
       data = list(), pars = NA, chains = 4,
       iter = 2000, warmup = floor(iter/2), thin = 1,
       init = "random", 
       seed = NULL, ## See below
       algorithm = c("NUTS", "HMC", "Fixed_param"),
       control = NULL,
       sample_file, diagnostic_file,
       save_dso = TRUE,
       verbose = FALSE, ...,
       boost_lib = NULL,
       eigen_lib = NULL, 
       pdebug = TRUE ## Additional argument
       ){

  tmp.filename <- paste('stan-debug',
                        gsub(' ', "-", Sys.time()), "txt",
                        sep='.')
  tmp.filename <- gsub(':', '.', tmp.filename )

  if (pdebug) message(paste('*** Parallel Stan run ***'))
  if (pdebug) message(paste('Working directory:'))
  if (pdebug) message(paste(' ', getwd(), sep=""))

  ## Should we compile the model?
  if( is.null(fit) ) {
    if (pdebug) message(" + Compiling the Stan model.")
    tryCatch( {
      extra_detail <- capture.output( suppressMessages(
        fit <- stan( file = file,
                     model_code = model_code,
                     model_name = model_name,
                     data = data,
                     chains     = 0, ... )))
      },
      error = function(e) {
        ## message('Error: model_code did not compile.')
        stop(e)
      }
    )
  } else {
    if (pdebug) message(" + Compiled Stan model supplied.")
  }

  ## Did we supply a seed?
  if ( is.null(seed) ) {
    rng_seed <- sample.int(.Machine$integer.max, 1)
  } else {
    rng_seed <- seed
  }

  if (chains > 0 ) {
    ## Setup the arguments for stan on the master node
    
    ## Step 1: Force evaluation of the elipsis arguments, if any
    ddots <- lapply(list(...), function(xx) {force(xx)})
    names(ddots) <- names(list(...))
    
    ## Step 2: Build the Stan argument list explicitly. Using force() requires R to evaluate
    ## the arguments while we are still on the master, so that the necessary pieces
    ## will get shipped to the cluster automatically
    stancall.list <- c(
      list(
        fit       = force(fit),
        data      = force(data),
        pars      = force(pars),
        chains    = force(chains),
        # if (!missing(chain_id)) chain_id  = force(chain_id) else list(),
        iter      = force(iter),
        warmup    = force(warmup),
        thin      = force(thin),
        init      = force(init),
        seed      = rng_seed, ## note the explicit change
        algorithm = force(algorithm),
        control   = force(control),
        # if (!missing(sample_file)) sample_file = force(sample_file) else list(),
        # if (!missing(diagnostic_file)) diagnostic_file = force(diagnostic_file) else list(),
        save_dso  = force(save_dso),
        verbose   = force(verbose)
      ),
      ddots,
      list(
        boost_lib = force(boost_lib),
        eigen_lib = force(eigen_lib)
      )
    )
    
    ## Check that, at a minimum, there are no repeated names
    if( length(unique( names(stancall.list))) != length(stancall.list) ) {
      repeated.args <- names( which( table(names(stancall.list)) > 1 ) )
      stop(paste("Error : Formal argument '", repeated.args, "' matched by multiple arguments\n", sep=""))
    }
    
    
    # Run in parallel if more than one chain
    if (chains > 1 ) {
      num.chains <- chains
      num.proc   <- min(detectCores(), num.chains)
      if (pdebug) message(paste(" + Attempting ", num.chains," chains on", num.proc, "cores."))

      if (pdebug) message('   ... Creating the cluster.')

      tryCatch( {
        ## Define a filename for output, if necessary
        cl <- NA
        if( pdebug ) {
          message(paste('   ... Log file:', tmp.filename), "")
          cl <- makeCluster( min(num.proc, num.chains), outfile=tmp.filename)
        } else {
          cl <- makeCluster( min(num.proc, num.chains))
        }

        if (pdebug) message('   ... Loading rstan on all workers.')
        test.loading <- parLapply(cl, 1:length(cl), function(xx){require(rstan)})
        if ( prod(unlist(test.loading)) != 1 | length(test.loading) != num.proc ) {
          stop('Error: rstan did not load on all workers.')
        }


        if (pdebug) message('   ... Exporting the fitted model and data to all workers.')


        ## browser()
        ## Export the stancall to the cluster
        clusterExport(cl, 'stancall.list', envir=environment())

        if (pdebug) message('   ... Running parallel chains.')
        fit.list <- parLapply(cl, 1:num.chains, function(ii) {
          ## lapply(1:num.chains, function(ii) {
          
          ## We are only running one chain per core; set accordingly
          stancall.list$chains   <- 1
          stancall.list$chain_id <- ii 
          ## N.B. The chain_id must be unique.
          
          ## If inits is a list, select only the correct chain for initialization
          if (is.list(stancall.list$init)) {
            stancall.list$init   <- stancall.list$init[ii]
          }
          
          return( do.call(stan, stancall.list ))
        })

      }, error = function(e) {
        ## If the parallel execution failed, we still return the compiled
        ## fit object
        stopCluster(cl)
        warning( e )
        return( fit )
      },
        finally = {
          stopCluster(cl)
      })

      ## Combine the objects into a single stan object (and update fit)
      tryCatch( {
        fit <- sflist2stanfit(fit.list) },
        error = function(e) {
          message('\n')
          message('Error in combining the results of parallel workers:')
          message(paste('   ',e$message))
          message('Returning a list with elements:')
          message('   fit            the compiled fit object')
          message('   parallel.list  the raw parallel results')
          message('   error          the error object')
          fit <<- list( fit = fit,
                        parallel.list = fit.list,
                        error = e)
        })
    } else {
      ## Only one chain was requested, run stan directly
      fit <- do.call(stan, stancall.list)
    }
    if (pdebug & 'stanfit' %in% is(fit)) message('   ... Finished!')
    return( fit )

  } else {
    ## Only wished to compile.
    return(fit)
  }
}
