#' Compile Bootstrap Sass with (optional) theming
#'
#' `bs_theme_dependencies()` compiles Bootstrap Sass into CSS and returns it,
#' along with other HTML dependencies, as a list of
#' [htmltools::htmlDependency()]s. Most users won't need to call this function
#' directly as Shiny & R Markdown will perform this compilation automatically
#' when handed a [bs_theme()]. If you're here looking to create a themeable
#' component, see [bs_dependency()].
#'
#' @section Sass caching and precompilation:
#'
#' If Shiny Developer Mode is enabled (by setting `options(shiny.devmode =
#' TRUE)` or calling `shiny::devmode(TRUE)`), both \pkg{sass} caching and
#' \pkg{bslib} precompilation are disabled by default; that is, a call to
#' `bs_theme_dependencies(theme)` expands to `bs_theme_dependencies(theme, cache
#' = F, precompiled = F)`). This is useful for local development as enabling
#' caching/precompilation may produce incorrect results if local changes are
#' made to bslib's source files.
#'
#' @inheritParams bs_theme_update
#' @param sass_options a [sass::sass_options()] object.
#' @param jquery a [jquerylib::jquery_core()] object.
#' @param precompiled Before compiling the theme object, first look for a
#'   precompiled CSS file for the [theme_version()].  If `precompiled = TRUE`
#'   and a precompiled CSS file exists for the theme object, it will be fetched
#'   immediately and not compiled. At the moment, we only provide precompiled
#'   CSS for "stock" builds of Bootstrap (i.e., no theming additions, Bootswatch
#'   themes, or non-default `sass_options`).
#' @inheritParams sass::sass
#'
#' @return Returns a list of HTML dependencies containing Bootstrap CSS,
#'   Bootstrap JavaScript, and `jquery`. This list may contain additional HTML
#'   dependencies if bundled with the `theme`.
#'
#' @export
#' @family Bootstrap theme functions
#'
#' @examplesIf rlang::is_interactive()
#'
#' # Function to preview the styling a (primary) Bootstrap button
#' library(htmltools)
#' button <- tags$a(class = "btn btn-primary", href = "#", role = "button", "Hello")
#' preview_button <- function(theme) {
#'   browsable(tags$body(bs_theme_dependencies(theme), button))
#' }
#'
#' # Latest Bootstrap
#' preview_button(bs_theme())
#' # Bootstrap 3
#' preview_button(bs_theme(3))
#' # Bootswatch 4 minty theme
#' preview_button(bs_theme(4, bootswatch = "minty"))
#' # Bootswatch 4 sketchy theme
#' preview_button(bs_theme(4, bootswatch = "sketchy"))
#'
bs_theme_dependencies <- function(
  theme,
  sass_options = sass::sass_options_get(output_style = "compressed"),
  cache = sass::sass_cache_get(),
  jquery = jquerylib::jquery_core(3),
  precompiled = get_precompiled_option("bslib.precompiled", default = TRUE)
) {
  theme <- as_bs_theme(theme)
  version <- theme_version(theme)

  if (isTRUE(version >= 5)) {
    register_runtime_package_check("`bs_theme(version = 5)`", "shiny", "1.7.0")
  }

  if (is.character(cache)) {
    cache <- sass_cache_get_dir(cache)
  }

  out_file <- maybe_precompiled_css(theme, sass_options, precompiled)

  if (is.null(out_file)) {
    out_file <- sass_compile_theme(theme, sass_options, cache)
  }

  htmltools::resolveDependencies(
    c(
      if (inherits(jquery, "html_dependency")) list(jquery) else jquery,
      list(
        htmlDependency(
          name = "bootstrap",
          version = get_exact_version(version),
          src = dirname(out_file),
          stylesheet = basename(out_file),
          script = basename(bootstrap_javascript(version)),
          all_files = TRUE, # include font and map files
          meta = list(
            viewport = "width=device-width, initial-scale=1, shrink-to-fit=no"
          )
        )
      ),
      htmlDependencies(out_file)
    )
  )
}

maybe_precompiled_css <- function(theme, sass_options, precompiled) {
  if (!precompiled) {
    return()
  }
  if (!identical(sass_options, sass_options(output_style = "compressed"))) {
    return()
  }

  precompiled_css <- precompiled_css_path(theme)
  if (is.null(precompiled_css)) {
    return()
  }

  version <- theme_version(theme)
  bs_js_hash <- rlang::hash_file(bootstrap_javascript(version))
  out_dir <- file.path(
    tempdir(),
    sprintf("bslib-precompiled-%s-%s", version, bs_js_hash)
  )

  out_file <- file.path(out_dir, basename(precompiled_css))
  out_file <- attachDependencies(out_file, htmlDependencies(as_sass(theme)))

  if (dir.exists(out_dir)) {
    # We've already copied all the files for this precompiled theme, there's no
    # need to copy them again.
    return(out_file)
  }

  dir.create(out_dir)
  file.copy(precompiled_css, out_file)

  # Usually sass() would handle file_attachments and dependencies,
  # but we need to do this manually
  write_file_attachments(
    as_sass_layer(theme)$file_attachments,
    out_dir
  )

  bootstrap_javascript_copy_assets(version, dirname(out_file))

  out_file
}

sass_compile_theme <- function(theme, sass_options, sass_cache) {
  version <- theme_version(theme)

  contrast_warn <- get_shiny_devmode_option(
    "bslib.color_contrast_warnings",
    default = FALSE,
    devmode_default = TRUE,
    devmode_message = paste(
      "Enabling warnings about low color contrasts found inside `bslib::bs_theme()`.",
      "To suppress these warnings, set `options(bslib.color_contrast_warnings = FALSE)`"
    )
  )
  theme <- bs_add_variables(theme, "color-contrast-warnings" = contrast_warn)

  out_file <- sass(
    input = theme,
    options = sass_options,
    output = output_template(basename = "bootstrap", dirname = "bslib-"),
    cache = sass_cache,
    write_attachments = TRUE,
    cache_key_extra = list(
      get_exact_version(version),
      get_package_version("bslib")
    )
  )

  bootstrap_javascript_copy_assets(version, dirname(out_file))

  out_file
}

bootstrap_javascript_copy_assets <- function(version, to) {
  js_files <- bootstrap_javascript(version)
  js_map_files <- bootstrap_javascript_map(version)
  success_js_files <- file.copy(c(js_files, js_map_files), to, overwrite = TRUE)
  if (any(!success_js_files)) {
    warning(
      "Failed to copy over bootstrap's javascript files into the htmlDependency() directory."
    )
  }
}

#' Themeable HTML components
#'
#' @description
#'
#' Themeable HTML components use Sass to generate CSS rules from Bootstrap Sass
#' variables, functions, and/or mixins (i.e., stuff inside of `theme`).
#' `bs_dependencies()` makes it a bit easier to create themeable components by
#' compiling [sass::sass()] (`input`) together with Bootstrap Sass inside of a
#' `theme`, and packaging up the result into an [htmltools::htmlDependency()].
#'
#' Themable components can also be  _dynamically_ themed inside of Shiny (i.e.,
#' they may be themed in 'real-time' via [bs_themer()], and more generally,
#' update their styles in response to [shiny::session]'s `setCurrentTheme()`
#' method). Dynamically themeable components provide a "recipe" (i.e., a
#' function) to `bs_dependency_defer()`, describing how to generate new CSS
#' stylesheet(s) from a new `theme`. This function is called when the HTML page
#' is first rendered, and may be invoked again with a new `theme` whenever
#' [shiny::session]'s `setCurrentTheme()` is called.
#'
#' @param input Sass rules to compile, using `theme`.
#' @param theme A [bs_theme()] object.
#' @param cache_key_extra Extra information to add to the sass cache key. It is
#'   useful to add the version of your package.
#' @param .dep_args A list of additional arguments to pass to
#'   [htmltools::htmlDependency()]. Note that `package` has no effect and
#'   `script` must be absolute path(s).
#' @param .sass_args A list of additional arguments to pass to
#'   [sass::sass_partial()].
#' @inheritParams htmltools::htmlDependency
#'
#' @references
#'   * [Theming: Custom components](https://rstudio.github.io/bslib/articles/custom-components/index.html)
#'     gives a tutorial on creating a dynamically themable custom component.
#'
#' @return `bs_dependency()` returns an [htmltools::htmlDependency()] and
#'   `bs_dependency_defer()` returns an [htmltools::tagFunction()]
#'
#' @family Bootstrap theme functions
#' @export
bs_dependency <- function(
  input = list(),
  theme,
  name,
  version,
  cache_key_extra = NULL,
  .dep_args = list(),
  .sass_args = list()
) {
  sass_args <- c(
    list(
      rules = input,
      bundle = theme,
      output = output_template(basename = name, dirname = name),
      write_attachments = TRUE,
      cache_key_extra = cache_key_extra
    ),
    .sass_args
  )
  outfile <- do.call(sass_partial, sass_args)

  dep_args <- list(
    name = name,
    version = version,
    src = dirname(outfile),
    stylesheet = basename(outfile)
  )

  bad_args <- intersect(names(.dep_args), names(dep_args))
  if (length(bad_args)) {
    stop(
      "The following `.dep_args` must be provided as top-level args to `bs_dependency()`: ",
      paste(bad_args, collapse = ", ")
    )
  }

  if ("package" %in% names(.dep_args)) {
    warning(
      "`package` won't have any effect since `src` must be an absolute path"
    )
  }

  script <- .dep_args[["script"]]
  if (length(script)) {
    if (basename(outfile) %in% basename(script)) {
      stop(
        "`script` file basename(s) must all be something other than ",
        basename(outfile)
      )
    }
    success <- file.copy(script, dirname(outfile), overwrite = TRUE)
    if (!all(success)) {
      stop(
        "Failed to copy the following script(s): ",
        paste(script[!success], collapse = ", "),
        ".\n\n",
        "Make sure script are absolute path(s)."
      )
    }
    .dep_args[["script"]] <- basename(script)
  }

  do.call(htmlDependency, c(dep_args, .dep_args))
}

#' @rdname bs_dependency
#' @param func a _non-anonymous_ function, with a _single_ argument.
#'   This function should accept a [bs_theme()] object and return a single
#'   [htmltools::htmlDependency()], a list of them, or `NULL`.
#' @param memoise whether or not to memoise (i.e., cache) `func` results for a
#'   short period of time. The default, `TRUE`, can have large performance
#'   benefits when many instances of the same themable widget are rendered. Note
#'   that you may want to avoid memoisation if `func` relies on side-effects
#'   (e.g., files on-disk) that need to change for each themable widget
#'   instance.
#'
#' @export
#'
#' @examplesIf rlang::is_interactive()
#' myWidgetVersion <- "1.2.3"
#'
#' myWidgetDependency <- function() {
#'   list(
#'     bs_dependency_defer(myWidgetCss),
#'     htmlDependency(
#'       name = "mywidget-js",
#'       version = myWidgetVersion,
#'       src = system.file(package = "mypackage", "js"),
#'       script = "mywidget.js"
#'     )
#'   )
#' }
#'
#' myWidgetCSS <- function(theme) {
#'   if (!is_bs_theme(theme)) {
#'     return(
#'       htmlDependency(
#'         name = "mywidget-css",
#'         version = myWidgetVersion,
#'         src = system.file(package = "mypackage", "css"),
#'         stylesheet = "mywidget.css"
#'       )
#'     )
#'   }
#'
#'   # Compile mywidget.scss using the variables and defaults from the theme
#'   # object.
#'   sass_input <- sass::sass_file(system.file(package = "mypackage", "scss/mywidget.scss"))
#'
#'   bs_dependency(
#'     input = sass_input,
#'     theme = theme,
#'     name = "mywidget",
#'     version = myWidgetVersion,
#'     cache_key_extra = utils::packageVersion("mypackage")
#'   )
#' }
#'
#' # Note that myWidgetDependency is not defined inside of myWidget. This is so
#' # that, if `myWidget()` is called multiple times, Shiny can tell that the
#' # function objects are identical and deduplicate them.
#' myWidget <- function(id) {
#'   div(
#'     id = id,
#'     span("myWidget"),
#'     myWidgetDependency()
#'   )
#' }
bs_dependency_defer <- function(func, memoise = TRUE) {
  # func() most likely calls stuff like sass_file() and bs_dependency() ->
  # sass_partial() -> sass() (e.g., see example section above) Even though
  # sass() calls can be cached, there is still considerable overhead involved
  # in computing the cache key itself because it involves file-level operations
  # (e.g. getting the mtimes of file attachments).
  # So, to help with performance (in the case where we repeatedly call the same
  # func with the same theme), memoise func with a short-lived cache
  if (memoise) {
    # The memoized function is created each time bs_dependency_defer is called,
    # and then it is used once. This is not how memoized functions are normally
    # used, but in this case it works because the caching object is re-used, and
    # it still provides very significant improvement in performance.
    mfunc <- memoise::memoise(func, cache = .dependency_cache)
  } else {
    mfunc <- func
  }

  tagFunction(function() {
    if (is_shiny_app()) {
      # If we're in a Shiny app, do two things:
      # (1) Register this function as a dependency so that Shiny will know to
      # update it later if the theme dynamically changes (i.e.,
      # session$setCurrentTheme() is called). Note that we *don't* provide
      # the memoised version since Shiny will de-duplicate identical()
      # functions anyway.
      # (2) Call the user's `func()` with the current theme, and return the
      # resulting htmlDependency so that it can be embedded in the static page.
      shiny::registerThemeDependency(func)

      return(mfunc(get_current_theme()))
    }

    # Outside of a Shiny context, we'll just get the global theme.
    mfunc(bs_global_get())
  })
}

as_bs_theme <- function(theme) {
  if (is_bs_theme(theme)) {
    return(theme)
  }

  # This is a historical artifact that should happen
  if (is_sass_bundle(theme) || inherits(theme, "sass_layer")) {
    stop(
      "`theme` cannot be a `sass_bundle()` or `sass_layer()` (use `bs_bundle()` to add a bundle)"
    )
  }

  # NULL means default Bootstrap
  if (is.null(theme)) {
    return(bs_theme())
  }

  # For example, `bs_theme_dependencies(theme = 4)`
  if (is.numeric(theme)) {
    return(bs_theme(version = theme))
  }

  # For example, `bs_theme_dependencies(theme = 'bootswatch@version')`
  if (is_string(theme)) {
    theme <- strsplit(theme, "@", fixed = TRUE)[[1]]
    if (length(theme) == 2) {
      return(bs_theme(version = theme[2], bootswatch = theme[1]))
    }
    # Also support `bs_theme_dependencies(version = '4')` and
    # `bs_theme_dependencies(theme = 'bootswatch')`
    if (length(theme) == 1) {
      if (theme %in% c(versions(), "4-3", "4+3")) {
        return(bs_theme(version = theme))
      } else {
        return(bs_theme(bootswatch = theme))
      }
    }
    stop("If `theme` is a string, it can't contain more than one @")
  }

  stop(
    "`theme` must be one of the following: (1) `NULL`, ",
    "(2) a `'bootswatch@version'` string, ",
    "(3) the result of `bs_global_get()`."
  )
}
