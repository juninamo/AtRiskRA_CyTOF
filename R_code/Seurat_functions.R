
# Functions
FindVariableGenesBatch <- function(exprs_mat, meta_df, genes_exclude = NULL, ngenes_use = 1e3, expr_min = .1) {
  if (!is.null(genes_exclude)) {
    genes_use <- setdiff(row.names(exprs_mat), genes_exclude)
  }
  x_res <- split(meta_df$cell, meta_df$sample) %>% lapply(function(x) {
    FindVariableGenesSeurat(exprs_mat[genes_use, x]) %>% 
      subset(gene.mean >= expr_min) %>% 
      tibble::rownames_to_column("gene") %>% 
      dplyr::arrange(-gene.dispersion) %>%
      head(ngenes_use)
  })
  data.table(Reduce(rbind, x_res))[, .N, by = gene][order(-N)]    
}


FindVariableGenesSeurat <- function (data, x.low.cutoff = 0.1, x.high.cutoff = 8,
                                     y.cutoff = 1, y.high.cutoff = Inf, num.bin = 0,
                                     binning.method = "equal_width", sort.results = TRUE,
                                     display.progress = TRUE, ...)
{
  genes.use <- rownames(data)
  if (class(data) != "dgCMatrix") {
    data <- as(as.matrix(data), "dgCMatrix")
  }
  ## (1) get means and variances
  gene.mean <- FastExpMean(data, display.progress)
  names(gene.mean) <- genes.use
  gene.dispersion <- FastLogVMR(data, display.progress)
  names(gene.dispersion) <- genes.use
  
  gene.dispersion[is.na(x = gene.dispersion)] <- 0
  gene.mean[is.na(x = gene.mean)] <- 0
  
  mv.df <- data.frame(gene.mean, gene.dispersion)
  rownames(mv.df) <- rownames(data)
  
  ## (OPTIONAL) do the binning correction
  if (num.bin > 0) {
    if (binning.method == "equal_width") {
      data_x_bin <- cut(x = gene.mean, breaks = num.bin)
    }
    else if (binning.method == "equal_frequency") {
      data_x_bin <- cut(x = gene.mean, breaks = c(-1, quantile(gene.mean[gene.mean >
                                                                           0], probs = seq(0, 1, length.out = num.bin))))
    }
    else {
      stop(paste0("Invalid selection: '", binning.method,
                  "' for 'binning.method'."))
    }
    names(x = data_x_bin) <- names(x = gene.mean)
    mean_y <- tapply(X = gene.dispersion, INDEX = data_x_bin,
                     FUN = mean)
    sd_y <- tapply(X = gene.dispersion, INDEX = data_x_bin,
                   FUN = sd)
    gene.dispersion.scaled <- (gene.dispersion - mean_y[as.numeric(x = data_x_bin)])/sd_y[as.numeric(x = data_x_bin)]
    gene.dispersion.scaled[is.na(x = gene.dispersion.scaled)] <- 0
    ##names(gene.dispersion.scaled) <- names(gene.mean)
    
    mv.df$gene.dispersion.scaled <- gene.dispersion.scaled
  }
  
  return(mv.df)
}

environment(FindVariableGenesSeurat) <- asNamespace("Seurat")

ScaleDataSeurat <- function (data.use, margin = 1, scale.max = 10,
                             block.size = 1000) {
  
  if (margin == 2) data.use %<>% t
  max.block <- ceiling(nrow(data.use)/block.size)
  
  ## Define data and functions to use in sparse and dense cases
  if (class(data.use) == "dgCMatrix" | class(data.use) == "dgTMatrix") {
    scale_fxn <- function(x) {
      FastSparseRowScale(mat = x, scale = TRUE, center = TRUE,
                         scale_max = scale.max, display_progress = FALSE)
    }
  } else {
    scale_fxn <- function(x) {
      FastRowScale(mat = x, scale = TRUE, center = TRUE,
                   scale_max = scale.max, display_progress = FALSE)
    }
    data.use <- as.matrix(data.use)
  }
  
  ## Do scaling, at once or in chunks
  if (max.block == 1) {
    scaled.data <- scale_fxn(data.use)
  } else {
    scaled.data <- matrix(NA, nrow(data.use), ncol(data.use))
    for (i in 1:max.block) {
      idx.min <- (block.size * (i - 1))
      idx.max <- min(nrow(data.use), (block.size * i - 1) + 1)
      my.inds <- idx.min:idx.max
      scaled.data[my.inds, ] <- scale_fxn(data.use[my.inds, , drop = F])
    }
  }
  
  colnames(scaled.data) <- colnames(data.use)
  row.names(scaled.data) <- row.names(data.use)
  scaled.data[is.na(scaled.data)] <- 0
  if (margin == 2) scaled.data %<>% t
  return(scaled.data)
}
environment(ScaleDataSeurat) <- asNamespace("Seurat")


fig.size <- function(height, width) {
  options(repr.plot.height = height, repr.plot.width = width)
}

SingleFeaturePlotSeurat <- function (data.use, feature, data.plot, pt.size, pch.use, cols.use,
                                     dim.codes, min.cutoff, max.cutoff, coord.fixed, no.axes,
                                     no.title = FALSE, no.legend, dark.theme, vector.friendly = FALSE,
                                     png.file = NULL, png.arguments = c(10, 10, 100))
{
  if (vector.friendly) {
    previous_call <- blank_call <- png_call <- match.call()
    blank_call$pt.size <- -1
    blank_call$vector.friendly <- FALSE
    png_call$no.axes <- TRUE
    png_call$no.legend <- TRUE
    png_call$vector.friendly <- FALSE
    png_call$no.title <- TRUE
    blank_plot <- eval(blank_call, sys.frame(sys.parent()))
    png_plot <- eval(png_call, sys.frame(sys.parent()))
    png.file <- SetIfNull(x = png.file, default = paste0(tempfile(),
                                                         ".png"))
    ggsave(filename = png.file, plot = png_plot, width = png.arguments[1],
           height = png.arguments[2], dpi = png.arguments[3])
    to_return <- AugmentPlot(blank_plot, png.file)
    file.remove(png.file)
    return(to_return)
  }
  idx.keep <- which(!is.na(data.use[feature, ]))
  data.gene <- data.frame(data.use[feature, idx.keep])
  #     data.gene <- na.omit(object = data.frame(data.use[feature,
  #         ]))
  min.cutoff <- SetQuantile(cutoff = min.cutoff, data = data.gene)
  max.cutoff <- SetQuantile(cutoff = max.cutoff, data = data.gene)
  data.gene <- sapply(X = data.gene, FUN = function(x) {
    return(ifelse(test = x < min.cutoff, yes = min.cutoff,
                  no = x))
  })
  data.gene <- sapply(X = data.gene, FUN = function(x) {
    return(ifelse(test = x > max.cutoff, yes = max.cutoff,
                  no = x))
  })
  data_plot <- data.plot[idx.keep, ]
  data_plot$gene <- data.gene
  if (length(x = cols.use) == 1) {
    brewer.gran <- brewer.pal.info[cols.use, ]$maxcolors
  }
  else {
    brewer.gran <- length(x = cols.use)
  }
  if (all(data.gene == 0)) {
    data.cut <- 0
  }
  else {
    data.cut <- as.numeric(x = as.factor(x = cut(x = as.numeric(x = data.gene),
                                                 breaks = brewer.gran)))
  }
  data_plot$col <- as.factor(x = data.cut)
  p <- data_plot %>%
    dplyr::arrange(col) %>%
    ggplot(mapping = aes(x = x, y = y))
  if (brewer.gran != 2) {
    if (length(x = cols.use) == 1) {
      p <- p + geom_point(mapping = aes(color = col), size = pt.size,
                          shape = pch.use) + #scale_color_brewer(palette = cols.use)
        scale_color_viridis(option = "plasma", end = .9)
    }
    else {
      p <- p + geom_point(mapping = aes(color = col), size = pt.size,
                          shape = pch.use) + #scale_color_manual(values = cols.use)
        scale_color_viridis(option = "plasma", end = .9)
    }
  }
  else {
    if (all(data_plot$gene == data_plot$gene[1])) {
      warning(paste0("All cells have the same value of ",
                     feature, "."))
      p <- p + geom_point(color = cols.use[1], size = pt.size,
                          shape = pch.use)
    }
    else {
      p <- p + geom_point(mapping = aes(color = gene),
                          size = pt.size, shape = pch.use) + scale_color_viridis(option = "plasma", end = .9
                          )
    }
  }
  if (dark.theme) {
    p <- p + DarkTheme()
  }
  if (no.axes) {
    p <- p + theme(axis.line = element_blank(), axis.text.x = element_blank(),
                   axis.text.y = element_blank(), axis.ticks = element_blank(),
                   axis.title.x = element_blank(), axis.title.y = element_blank())
    if (!no.title)
      p <- p + labs(title = feature, x = "", y = "")
    if (no.title)
      p <- p + labs(x = "", y = "")
  }
  else {
    if (no.title)
      p <- p + labs(x = dim.codes[1], y = dim.codes[2])
    if (!(no.title))
      p <- p + labs(title = feature) + labs(x = "", y = "")
  }
  if (no.legend) {
    p <- p + theme(legend.position = "none")
  }
  if (coord.fixed) {
    p <- p + coord_fixed()
  }
  return(p)
}
environment(SingleFeaturePlotSeurat) <- asNamespace("Seurat")

PlotFeatures <- function(umap_use, features_plot, exprs_use, cells_use, ncols, pt_size = .5, pt_shape = ".", q_lo = "q10", q_hi = "q90") {
  if (missing(cells_use)) cells_use <- 1:nrow(umap_use)
  if (missing(ncols)) ncols <- round(sqrt(length(features_plot)))
  
  plt_list <- lapply(features_plot, function(feature_use) {
    SingleFeaturePlotSeurat(exprs_use[, cells_use], feature_use, data.frame(x = umap_use[cells_use, 1], y = umap_use[cells_use, 2]),
                            pt.size = pt_size, pch.use = pt_shape, cols.use = c("lightgrey", "blue"),
                            dim.codes = c("UMAP 1", "UMAP 2"), min.cutoff = c(q10 = q_lo), max.cutoff = c(q90 = q_hi),
                            coord.fixed = FALSE, no.axes = FALSE, dark.theme = FALSE, no.legend = TRUE)
  })
  plot_grid(plotlist = plt_list, ncol = ncols)
  #return(plt_list)
}

BuildSNNSeurat <- function (data.use, k.param = 30, prune.SNN = 1/15, nn.eps = 0) {
  my.knn <- nn2(data = data.use, k = k.param, searchtype = "standard", eps = nn.eps)
  nn.ranked <- my.knn$nn.idx
  
  snn_res <- ComputeSNN(nn_ranked = nn.ranked, prune = prune.SNN)
  rownames(snn_res) <- row.names(data.use)
  colnames(snn_res) <- row.names(data.use)
  return(snn_res)
}
environment(BuildSNNSeurat) <- asNamespace("Seurat")

NormalizeDataSeurat <- function(A, scaling_factor = 1e4, do_ftt = FALSE) {
  A@x <- A@x / rep.int(Matrix::colSums(A), diff(A@p))
  A@x <- scaling_factor * A@x
  if (do_ftt) {
    A@x <- sqrt(A@x) + sqrt(1 + A@x)
  } else {
    A@x <- log(1 + A@x)
  }
  return(A)
}

plot_clusters3 <- function(cluster_ids, labels, pt_size = 14, umap_use = umap_post, do_labels = FALSE) {
  cluster_table <- table(cluster_ids)
  clusters_keep <- names(which(cluster_table > 20))
  plt_df <- umap_use %>% data.frame() %>% cbind(cluster = cluster_ids) %>%
    subset(cluster %in% clusters_keep) 
  plt <- plt_df %>% 
    ggplot(aes(X1, X2, col = factor(cluster))) + geom_point(shape = '.', alpha = .6) + 
    theme_tufte() + geom_rangeframe(col = "black") + 
    #         theme(axis.line = element_line()) +
    guides(color = guide_legend(override.aes = list(stroke = 1, alpha = 1, shape = 21, size = 4))) + 
    scale_color_manual(values = singler.colors) +
    labs(x = "UMAP 1", y = "UMAP 2") +
    theme(plot.title = element_text(hjust = .5)) + 
    guides(col = FALSE)
  
  if (do_labels) 
    plt <- plt + geom_label(data = data.table(plt_df)[, .(X1 = mean(X1), X2 = mean(X2)), by = cluster], 
                            aes(label = cluster), size = pt_size, alpha = .8)
  return(plt)
}

