FROM python:3.12-alpine
WORKDIR /app
COPY shim.py /app/shim.py
USER 65534:65534
EXPOSE 8192
CMD ["python", "/app/shim.py"]
