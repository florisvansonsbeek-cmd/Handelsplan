# Handelsplan 2027 op Railway. Railway vindt dit bestand vanzelf en bouwt de site ermee.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .
# Bouwt app/pages/index.html uit page/handelsplan.html
RUN python page/build.py

EXPOSE 8080
# Tabellen, startgegevens en de planner start de app zelf zodra PostgreSQL bereikbaar is.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --proxy-headers --forwarded-allow-ips='*'"]
