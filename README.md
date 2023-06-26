# Promtheus wetter-com exporter

I personally use wetter.com quite often as the single source of truth,
to checkout how it outperforms on my location and how reliable it especially
in terms of rain predictions, i'd started to capute the data for some time.

### Usage

```bash
docker-compose up -d
```

and start scraping by adding something like this to you prometheus config.

```yaml
  - job_name: wettercom_exporter
    scrape_interval: 1m
    static_configs:
      - targets: [DEXXX0241] # extracted from the URL
        labels: { location: "Regensburg" }
      - targets: [DE0006194] # https://www.wetter.com/deutschland/leipzig/DE0006194.html 
        labels: { location: "Leipzig" }
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: internal.prom.klaut.io:9294
```
