# Handelsplan 2027

Je handelsplan (Markt, Cyclus, Plan, Signalen, Inbox, **Post**, Historie) op Railway, met:

- **Inloggen met één wachtwoord** (`APP_PASSWORD`); zonder inlog is niets te zien. HTTP wordt doorgestuurd naar HTTPS.
- **PostgreSQL** (`DATABASE_URL`) voor je plan, verwerkte mails, documenten, koersen, notities en het logboek. De tabellen maakt de site zelf aan.
- **E-mail via IMAP** (iCloud): elk kwartier nieuwe mails ophalen, alleen lezen. Bijlagen (PDF, Word, Excel, PowerPoint, HTML, tekst, JPG/PNG) worden omgezet naar tekst.
- **Grok** (`XAI_API_KEY`) haalt per mail en bijlage de handelsinformatie eruit: soort document, samenvatting, bedrijven, tickers, bedragen, datums, belang en acties. Grok doet ook de transcriptanalyse en "Vraag het plan".
- **Dashboard (tab Post)**: alle verwerkte mails en documenten met filters, koersen van je volglijst, notities en een logboek. Met één klik zet je een document in de Inbox van je plan.
- **Live koersen** (optioneel `FINNHUB_API_KEY`); crypto komt van CoinGecko.
- **Foutafhandeling**: mailserver weg, verkeerd wachtwoord, API-limiet of database even niet bereikbaar? Dan komt er een melding in het logboek en draait de rest gewoon door.

> **Zet deze repository op privé** (GitHub → Settings → Danger Zone → Change visibility). Er staat je plan in. Sleutels en wachtwoorden horen alleen in Railway → Variables, nooit in GitHub.

## Instellen in Railway

1. **Database:** in je project → **Create** → **Database** → **PostgreSQL**. Ga daarna naar je website-dienst → **Variables** → **Add Variable Reference** → `DATABASE_URL` van de Postgres-dienst (staat hij er al, dan is dit klaar).
2. **Variabelen** (dienst → Variables → Raw Editor):
   ```
   APP_PASSWORD=een-lang-uniek-wachtwoord
   XAI_API_KEY=
   EMAIL_HOST=imap.mail.me.com
   EMAIL_PORT=993
   EMAIL_USER=
   EMAIL_PASS=
   FINNHUB_API_KEY=
   ```
   - `EMAIL_USER` is je Apple ID-adres (de iCloud-mailbox), `EMAIL_PASS` een **app-specifiek wachtwoord** (account.apple.com → Aanmelden en beveiliging → App-specifieke wachtwoorden), niet je Apple ID-wachtwoord.
   - Tip: maak in iCloud Mail een map **Handelsplan** met een regel (bijv. alles van je broker) en zet `EMAIL_FOLDER=Handelsplan`. Dan leest Grok alleen die mails en niet je hele inbox.
   - Klik bovenaan op **Deploy** om de wijzigingen door te voeren.
3. **Inloggen:** open je site en log in met `APP_PASSWORD`.
4. Optioneel: `NTFY_TOPIC` (push naar je telefoon), `FRED_API_KEY` en `TWELVEDATA_API_KEY` (macrocijfers op de Markt-pagina), `INBOX_TOKEN` (transcripts vanaf je laptop), `EMAIL_SINCE_DAYS` (hoe ver terug bij de eerste keer, standaard 14), `XAI_MODEL` (standaard grok-4.7). Alles staat in `.env.example`.

Gebruik één exemplaar (geen replicas) en laat Serverless uit: de planner voor mail en koersen draait in de site zelf.

## Gegevens uit de losse Chrome-versie meenemen

In de losse versie: **Uitleg → Back-up downloaden**. Op je Railway-site: **Uitleg → Back-up terugzetten** en kies dat bestand.

## Hoe het in elkaar zit

| Bestand | Wat |
|---|---|
| `app/main.py` | Server: inlog, HTTPS, pagina's en alle API's |
| `app/db.py` | PostgreSQL: tabellen `docs`, `mails`, `documents`, `quotes`, `watchlist`, `notes`, `events`, `kv`, `ai_usage` |
| `app/mail.py` | IMAP ophalen en tekst uit bijlagen halen |
| `app/analyze.py` | Grok-analyse van mails en bijlagen |
| `app/ai.py` | Koppeling met Grok (xAI), of Claude als je `ANTHROPIC_API_KEY` gebruikt |
| `app/quotes.py` | Koersen (Finnhub, CoinGecko) |
| `app/scheduler.py`, `app/jobs.py` | Planner: mail elk kwartier, koersen elk kwartier, macrocijfers 's avonds |
| `page/handelsplan.html` | De pagina; bij het bouwen wordt hier `app/pages/index.html` van gemaakt |
| `seed/` | Je startplan en de cyclus-analyse; alleen ontbrekende onderdelen worden toegevoegd |

Persoonlijk educatief plan. Geen beleggingsadvies.
