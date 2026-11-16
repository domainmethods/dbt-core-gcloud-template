# Use the official dbt-core image as the base (latest 1.10 patch)
FROM ghcr.io/dbt-labs/dbt-core:1.10.8

WORKDIR /app

# Python hooks may import from /app; ensure it's on the path
ENV PYTHONPATH=/app
ENV DBT_PROFILES_DIR=/app/profiles

# Copy core project files needed at runtime
# package-lock.y[m]l: the glob copies the lock when it exists and doesn't fail the build
# if an adopter deletes it, so the container's `dbt deps` installs the locked versions.
COPY dbt_project.yml packages.yml package-lock.y[m]l requirements.txt ./
COPY profiles/ ./profiles/
COPY macros/ ./macros/
COPY models/ ./models/
# seeds/, snapshots/ and tests/ are optional — ensure dirs exist for COPY
RUN mkdir -p seeds snapshots tests
COPY seeds/ ./seeds/
COPY snapshots/ ./snapshots/
# Singular data tests; without this, prod `dbt build` silently skips them
COPY tests/ ./tests/
COPY hooks/ ./hooks/
COPY scripts/lib/ ./scripts/lib/

RUN pip install --no-cache-dir -r requirements.txt

ENV DBT_TARGET=prod

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
