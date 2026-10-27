FROM python:3.11-slim

# Install libmagic and build-essential
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libicu-dev \
    libmagic1 \
    libmagic-dev \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Create a directory for the virtual environment
RUN python -m venv /venv

# Prioritize the virtual environment
ENV PATH="/venv/bin:$PATH"

# Upgrade pip and install Python dependencies
RUN pip3 install --upgrade pip && \
    pip3 install \
        pyyaml \
        pluggy==1.6.0 \
        scancode-toolkit

# Copy the entrypoint script into the image
COPY entrypoint.sh /entrypoint.sh

# Make the entrypoint script executable
RUN chmod +x /entrypoint.sh

# Set the entrypoint
ENTRYPOINT ["/entrypoint.sh"]
