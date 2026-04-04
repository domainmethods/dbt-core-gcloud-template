# Use the official dbt-core image as the base (latest 1.10 patch)
FROM ghcr.io/dbt-labs/dbt-core:1.10.8

# Install the dbt-bigquery adapter
RUN pip install "dbt-bigquery==1.10.1"

WORKDIR /app

# Python hooks may import from /app; ensure it's on the path
ENV PYTHONPATH=/app
ENV DBT_PROFILES_DIR=/app/profiles

# Copy core project files needed at runtime
COPY dbt_project.yml packages.yml requirements.txt ./
COPY profiles/ ./profiles/
COPY macros/ ./macros/
COPY models/ ./models/
COPY seeds/ ./seeds/
COPY snapshots/ ./snapshots/
COPY hooks/ ./hooks/

RUN pip install --no-cache-dir -r requirements.txt

ENV DBT_TARGET=prod

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
