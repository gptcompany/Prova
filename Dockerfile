# Use a smaller Python Alpine base image
FROM python:3.9.16-alpine

# Set environment variables
ARG GTB_ACCESS_TOKEN
ENV GTB_ACCESS_TOKEN=${GTB_ACCESS_TOKEN}
ARG AWS_REGION
ENV AWS_REGION=${AWS_REGION}
ARG AMAZON_ACCESS_KEY
ENV AMAZON_ACCESS_KEY=${AMAZON_ACCESS_KEY}
ARG AMAZON_SECRET_ACCESS_KEY
ENV AMAZON_SECRET_ACCESS_KEY=${AMAZON_SECRET_ACCESS_KEY}

# Set the working directory
WORKDIR /code

# Copy necessary files
COPY ./feed/pyproject.toml ./feed/poetry.lock* ./
COPY ./cloudformation ./cloudformation
COPY ./README.md /code/
COPY ./feed ./feed

# Install dependencies in one layer, and clean up in the same layer to minimize size
RUN apk add --no-cache gcc musl-dev && \
    pip install poetry==1.6.1 && \
    poetry config virtualenvs.create false && \
    poetry install --no-interaction --no-ansi --no-root && \
    apk del gcc musl-dev

# Expose necessary ports
EXPOSE 5432
EXPOSE 6379
