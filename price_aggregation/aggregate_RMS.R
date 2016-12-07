# This R script handles price and quantity aggregation in RMS and Homescan Data
library(bit64)
library(data.table)
library(foreach)
library(doParallel)

registerDoParallel(cores = NULL)

run_grid = T

if(!run_grid){
  load('Booth/price_aggregation/Meta-Data-Corrected.RData')
  load('Booth/price_aggregation/Products-Corrected.RData')
  # Sample file
  load('Booth/price_aggregation/1356240001.RData')
} else {
  load('/grpshares/hitsch_shapiro_ads/data/RMS/Meta-Data/Products-Corrected.RData')
  # Get top 100 brands and their competitors to aggregate
  competitors_RMS = readRDS('~/top_brands.rds')
  brands_RMS = readRDS('~/brands_RMS.rds')
  topmodulenames = brands_RMS$product_module_descr[1:100]
  competitors_RMS = competitors_RMS[product_module_descr %in% topmodulenames]
  setorder(competitors_RMS, rev_sum)
  topbrandcodes = competitors_RMS$brand_code_uc
  topmodulecodes = lapply(competitors_RMS$product_module_descr, 
                          function(x){products[product_module_descr==x]$product_module_code[1]})
  # Drop unnecessary products columns
  descr_cols = grep("descr", names(products))
  products[, c(descr_cols):=NULL]
}

source_dir = '/grpshares/ghitsch/data/RMS-Build-2016/RMS-Processed/Modules'
output_dir = '/grpshares/hitsch_shapiro_ads/data/RMS/Brand-Aggregates'

## Helper functions -----------
# Function to fill in NA prices
Fill.NA.Prices <- function(DT){
  # Is deep copy necessary?
  # move = copy(DT)
  vars = c("upc", "upc_ver_uc_corrected", "store_code_uc", "week_end", "base_price")
  setkeyv(move, vars[-5])
  inds = match(vars, colnames(move))
  bps  = move[, inds, with=FALSE]
  str  = bps[, -5, with=FALSE]
  bps  = bps[!is.na(base_price)]
  bps  = bps[str, roll=TRUE, rollends=c(TRUE, TRUE)]
  move[, base_price:=bps$base_price]
  move[is.na(imputed_price), imputed_price:=base_price]
  # At this point, if base price still has NA, it must be all NA
  # These stores are effectively un-processed
  move[is.na(base_price), processed := FALSE]
  return(move)
}

# Function that does brand aggregation
brandAggregator = function(DT, weight_type, promotion_threshold, processed_only = TRUE){
  if(processed_only){
    DT = DT[processed==T]
  }
  brand_codes = unique(DT$brand_code_uc_corrected)
  print(brand_codes)
  if(length(brand_codes)>0){
    DT_brands = list()
    for(i in 1:length(brand_codes)){
      brand_code = brand_codes[[i]]
      DT_brand = DT[brand_code_uc_corrected==brand_code]
      # Quantity Aggregation
      # Assumption that every row in movement is unique by product-store-week
      DT_brand[, volume:=size1_amount*multi]
      DT_brand[, quantity:=units*volume]
      
      # Price Aggregation
      DT_brand[, revenue:=imputed_price*units]
      if(weight_type=="store-revenue/week"){
        DT_brand[, week_range:=as.integer(difftime(max(week_end), min(week_end), units="weeks")),
                 by=c("upc", "upc_ver_uc_corrected", "store_code_uc")]
        DT_brand[, weight:=sum(revenue, na.rm=T)/week_range, by=c("upc", "upc_ver_uc_corrected", "store_code_uc")]
        DT_brand[, price_weight:=weight*!is.na(imputed_price)] 
        DT_brand[, equiv_price_weighted:=price_weight*imputed_price/volume]
      } else if(weight_type=="total revenue"){
        DT_brand[, weight:=sum(revenue, na.rm=T), by=c("upc", "upc_ver_uc_corrected")]
        DT_brand[, price_weight:=weight*!is.na(imputed_price)] 
        DT_brand[, equiv_price_weighted:=price_weight*imputed_price/volume]
      }
      
      # Promotion Aggregation
      threshold = promotion_threshold
      DT_brand[, promo_weight:=weight*(!is.na(base_price)&!is.na(imputed_price))] 
      DT_brand[, promotion:=(base_price-imputed_price)/base_price > threshold]
      DT_brand[, promotion_weighted:=promo_weight*promotion]
      
      # Base Price Aggregation
      DT_brand[, base_weight:=weight*!is.na(base_price)] 
      DT_brand[, base_price_weighted:=base_weight*base_price/volume]
      
      # Aggregation Process
      DT_brand = DT_brand[, .(units=sum(quantity, na.rm=T), 
                              equiv_price_weighted=sum(equiv_price_weighted, na.rm=T),
                              promotion_weighted=sum(promotion_weighted, na.rm=T),
                              base_price_weighted=sum(base_price_weighted, na.rm=T),
                              price_weight_sum=sum(price_weight),
                              promo_weight_sum=sum(promo_weight),
                              base_weight_sum=sum(base_weight)),
                          by=c("brand_code_uc_corrected", "product_module_code", "store_code_uc", "week_end")]
      DT_brand[, `:=`(price=equiv_price_weighted/price_weight_sum,
                      promo_percentage=promotion_weighted/promo_weight_sum,
                      base_price=base_price_weighted/base_weight_sum)]
      DT_brand[, promo_dummy:=(base_price-price)/base_price > threshold]
      DT_brand = DT_brand[, .(brand_code_uc_corrected, product_module_code, store_code_uc, week_end,
                              price, units, base_price, promo_percentage, promo_dummy)]
      DT_brands[[i]] = DT_brand
    }
    output = rbindlist(DT_brands)
    return(output)
  }
  return(DT) # empty data table
}

# Stack upc files for a specified brand
brand_upcs = function(brand_code, module_code){
  upc_list = unique(products[brand_code_uc==brand_code & 
                               product_module_code==module_code &
                               (dataset_found_uc=='ALL' | dataset_found_uc=='RMS')]$upc)
  upc_list = paste0(upc_list,'.RData')
  return(upc_list)
}

#foreach(k = length(topbrandcodes):1) %dopar% { 
for(k in 771:1){
  print(k)
  brand_code = topbrandcodes[[k]] # Bud light = 520795, Coca-Cola R = 531429
  module_code = topmodulecodes[[k]] # Bud light = 5010, Coca-Cola = 1484
  print(brand_code)
  
  upc_filenames = paste(source_dir, module_code, brand_upcs(brand_code, module_code), sep='/')
  upc_files = list()
  for(i in 1:length(upc_filenames)){
    filename = upc_filenames[[i]]
    if(file.exists(filename)){
      load(filename)
      upc_files[[i]] = move
    } else {
      #print(paste(basename(filename), "doesn't exist."))
    }
  }
  
  print("Bind product files...")
  DT = rbindlist(upc_files)
  print(nrow(DT))
  print("Fill NA...")
  DT = Fill.NA.Prices(DT)
  print("Begin aggregation...")
  row_DT = nrow(DT)
  DT = merge(DT, products, by=c("upc","upc_ver_uc_corrected"), allow.cartesian=T)
  if(nrow(DT)>row_DT){
    # Still don't know why this happens, unless there are duplicates in the products table
    # which there are not 
    print("CARTESIAN JOIN!-------------------------------")
    print(table(DT$brand_code_uc_corrected))
  }
  print(unique(DT$brand_code_uc_corrected))
  # Some products belong to multiple brands when upc_ver changes? 
  DT = DT[brand_code_uc_corrected==brand_code]
  print(nrow(DT))
  aggregated = brandAggregator(DT, "total revenue", 0.05)
  #print(head(aggregated))
  #print(nrow(aggregated))
  #print(summary(aggregated$base_price))
  #print(summary(aggregated$price))
  if(nrow(aggregated)>0){
    print("Saving...")
    dir.create(file.path(output_dir, toString(module_code)), showWarnings = FALSE)
    saveRDS(aggregated, file.path(output_dir, toString(module_code), paste0(toString(brand_code),'.rds')))
  } else {
    print("Skipping saving -- empty data table because processed=F for all values...")
  }
  gc()
  
}

if(!run_grid){
  load('Booth/price_aggregation/Old_Brand_Aggregate.RData')
  budlight = test_data[brand_group_code == 20929]
  cocacola = test_data[brand_group_code==30886]
  budlight2 = readRDS('Booth/price_aggregation/aggregated_brands2.rds')
  cocacola2 = readRDS('Booth/price_aggregation/aggregated_brands.rds')
  compare = merge(budlight, budlight2, by=c("store_code_uc","week_end"))
  compare = merge(cocacola, cocacola2, by=c("store_code_uc","week_end"))
  cor(compare$price, compare$imputed_price_hybrid, use="pairwise.complete.obs")
  cor(compare$base_price, compare$base_price_hybrid, use="pairwise.complete.obs")
  cor(compare$promo_percentage, compare$promotion_freq_5, use="pairwise.complete.obs")
}