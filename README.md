# Handelsplan 2027

Je handelsplan op Railway, in vier tabs plus Uitleg:

| Tab | Wat erin staat |
|-----|----------------|
| **Vandaag** | Het verhaal (wat speelt er, wat betekent het, wat doe je), per tab in het kort, de vooruitblik met het effect op elke belegging, en Tino en Gammon naast de AI |
| **Plan** | Wanneer bijkopen (per belegging: nu, wanneer wel en hoeveel, alleen uit je eigen regels), de cijfers die je regels sturen, per positie wat je hebt en je regels als ladder; daaronder portefeuille, scenario's en Eightcap-challenges (uitklapbaar) |
| **Markt** | Overzicht, Signalen, Cyclus en Cijfers (subtabs) |
| **Inbox** | Transcripts, Post (verwerkte mail) en Historie (subtabs) |

Bovenaan Plan, Markt en Inbox staat een strook **In het kort** met hetzelfde verhaal als op Vandaag. Informatie heeft een label: **Doen** (alleen hierop handel je), **Volgen** (de paar cijfers en momenten die je regels sturen) en **Achtergrond** (begrijpen waarom). Een nieuw bezoek begint altijd op Vandaag; oude links zoals `#historie`, `#cyclus` of `#kompas` werken nog.

Met:

- **Vandaag** (startpagina) vertelt één verhaal:
  - **Het verhaal**: de kop van de dag, *wat er speelt*, *wat het betekent* voor je posities en *wat je doet* (alleen geraakte planregels, met de knop Gedaan/Gezien en het bedrag uit je portefeuille).
  - **In het kort per onderdeel**: Plan (wat je nu doet, waar bijkopen nu mag, de volgende koopkans en waar een rem op staat), Markt (nu, korte termijn met wat zeer waarschijnlijk is, langere termijn) en Inbox, elk met een knop erheen.
  - **Wat kun je verwachten**: links de korte termijn (wat zeer waarschijnlijk is en de momenten die het beeld kunnen kantelen), rechts de langere termijn (3 tot 12 maanden, met de kans per scenario). Daaronder per belegging: komende weken, langere termijn en of bijkopen nu kan.
  - **Zijnoot: Tino en Gammon naast de AI**: of TradersReality (Tino) en Rebel Capitalist (George Gammon) het eens, deels eens of oneens zijn met de analyse, en waarin. Zolang er geen transcript van een bron is verwerkt, staat er eerlijk "nog onbekend".
  - Daarnaast je portefeuille en wat er veranderde sinds je vorige bezoek.
- **Plan**: een kaart per positie met wat je nu doet, wat je hebt (aantal, waarde, weging tegenover je doel) en je regels als ladder met de huidige koers ertussen. De **portefeuille** vul je in onder Plan → Portefeuille; de site rekent waarde, winst, weging en de bedragen van je planregels uit (bijv. "SMH een derde kleiner = ca. € 2.984"). Alles blijft in je eigen database.
- **Automatische marktdata zonder sleutels**: Yahoo Finance (koersen elk kwartier op werkdagen), FRED van de St. Louis Fed (rente, inflatie, banen, liquiditeit, twee keer per dag) en CoinGecko (bitcoin; reserve voor goud, zilver en de euro). Een cijfer wordt nooit overschreven door een oudere waarneming, en bij elk cijfer staat hoe oud het is.
  - Yahoo en de FRED-site weigeren gewone scripts vanaf servers; de site haalt ze daarom op met de verbindingsvingerafdruk van Chrome (`curl_cffi`, zoals yfinance).
  - Blokkeert een bron toch, dan wordt die even overgeslagen (Yahoo 15 min, FRED 30 min) en vullen de andere bronnen aan. De planner loopt nooit vast.
  - Betrouwbaarder voor FRED: vraag een gratis sleutel aan op fred.stlouisfed.org (My Account → API Keys) en zet die als `FRED_API_KEY` in Railway.
- **Planregels met meldingen**: elke positie heeft regels (bijv. "SMH onder $500: verklein met een derde"). Raakt de koers zo'n regel, dan krijg je één melding (ntfy, of mail als die werkt). Met *Gedaan* of *Gezien* zet je hem uit; hij staat pas weer scherp als de koers eerst duidelijk terug is geweest, zodat heen-en-weer rond een niveau geen dubbele meldingen geeft.
- **Bron herkennen**: de bron staat standaard op *Automatisch*. Na een document of een lang geplakt transcript bepaalt Grok (snel model, begin en eind van de tekst) wat voor bron het is (video-transcript, artikel, rapport, melding…) en van wie, en vult hij bron, titel en datum in, met de aanwijzing erbij ("Herkend door Grok: video-transcript van George Gammon (Rebel Capitalist) · zeker"). Kies je zelf een bron, dan gaat die voor. TradersReality of Rebel Capitalist wordt alleen gekozen als Grok zeker of vrij zeker is; bij een gok wordt het *Overig* en blijft de bril van Tino of Gammon ongemoeid. Lukt herkennen niet, dan wordt het *Overig*. Wat Grok herkende staat bij het inbox-item (`who`), in de analyse en bij het voorstel.
- **Transcripts analyseren** (Inbox → Transcripts): plak een transcript en klik op Analyseer. Je kunt ook een **document** toevoegen (Bestand kiezen, het ergens op de site neerslepen, of een screenshot plakken; vanaf elke tab kom je vanzelf bij het formulier): pdf, Word, Excel, PowerPoint, OpenDocument, rtf, tekst, e-mail (.eml), ondertitels (.srt/.vtt, zonder tijden en herhalingen) of een afbeelding (JPG/PNG, Grok leest de tekst en cijfers), tot 20 MB. De server haalt de tekst eruit (`POST /api/extract`, `app/extract.py`) en zet die in het tekstveld; het bestand zelf wordt niet bewaard. Een gescande pdf zonder tekst geeft een nette melding (maak er dan een screenshot van). De analyse draait als taak op de server en de pagina vraagt elke paar seconden de stand op, met een teller erbij. Je mag de pagina sluiten: bij terugkomst haalt hij het resultaat op, en *Voorstellen bekijken* blijft beschikbaar bij het item. Herstart de server tijdens een analyse, dan start die vanzelf opnieuw.
- **Dagbriefing van Grok**: elke werkdag om 08:05 en 22:35 een korte briefing, alleen op basis van de cijfers, planregels, scenario's en brillen op de site (geen verzonnen nieuws). Grok schrijft daarin ook het verhaal voor Vandaag, de vooruitblik per belegging en de vergelijking van Tino en Gammon met de AI. Verwerk je een transcript van Tino of Gammon, dan maakt de analyse die vergelijking meteen opnieuw. De site kiest zelf uit de Grok-modellen van je account: een snel model voor mail en een snel redenerend model voor analyses (bijv. grok-4-1-fast-reasoning). Een groot redenerend model deed over een lang transcript meer dan 5 minuten. Met `XAI_MODEL` en `XAI_MODEL_COMPLEX` kies je zelf.

- **Inloggen met één wachtwoord of een pincode** (`APP_PASSWORD`); zonder inlog is niets te zien. HTTP wordt doorgestuurd naar HTTPS.
  - Bestaat `APP_PASSWORD` uit 4 tot 8 cijfers, dan toont het inlogscherm een pincodeveld dat vanzelf inlogt.
  - **Bekende apparaten**: een browser of losse html waarop je één keer goed inlogt, krijgt een ondertekend apparaatbewijs (400 dagen geldig). Een bot die steeds een foute pincode probeert, kan je daardoor niet meer buitensluiten.
  - Grenzen voor onbekende apparaten: 5 foute pogingen per 15 minuten per adres, 4 per 24 uur per netwerk en 10 per 24 uur samen (`LOGIN_DAILY_LIMIT`). Een bekend apparaat heeft alleen zijn eigen grens (10 per 24 uur). De tellers staan in de database en overleven een herstart; een pincode van 4 cijfers raden duurt zo jaren.
  - In het verbindingspaneel (knop *Railway* bovenaan) staat onder **Inloggen** hoeveel foute pogingen er waren en vanaf welk netwerk.
  - Is inloggen dicht voor nieuwe apparaten? Je bekende apparaten werken gewoon. Wil je meteen op een nieuw apparaat, wijzig dan `APP_PASSWORD` in Railway; dat zet alle tellers op nul.
- **PostgreSQL** (`DATABASE_URL`) voor je plan, verwerkte mails, documenten, koersen, notities en het logboek. De tabellen maakt de site zelf aan.
- **E-mail via IMAP** (iCloud): elk kwartier nieuwe mails ophalen, alleen lezen. Bijlagen (PDF, Word, Excel, PowerPoint, HTML, tekst, JPG/PNG) worden omgezet naar tekst.
- **Grok** (`XAI_API_KEY`) haalt per mail en bijlage de handelsinformatie eruit: soort document, samenvatting, bedrijven, tickers, bedragen, datums, belang en acties. Grok doet ook de transcriptanalyse en "Vraag het plan".
- **Dashboard (tab Post)**: alle verwerkte mails en documenten met filters, koersen van je volglijst, notities en een logboek. Met één klik zet je een document in de Inbox van je plan.
- **Volglijst** elk kwartier: via Finnhub als je `FINNHUB_API_KEY` hebt, anders (of bij een limiet) via Yahoo Finance; crypto via CoinGecko.
- **Verbindingsstatus**: bovenin de site zie je of Railway verbonden is (groen, oranje of rood). Klik erop voor de echte test per koppeling: database, Grok, e-mail en Finnhub. Ook het inlogscherm laat al zien of de server en de database bereikbaar zijn.
- **Foutafhandeling**: mailserver weg, verkeerd wachtwoord, API-limiet of database even niet bereikbaar? Dan komt er een melding in het logboek en draait de rest gewoon door.

> **Zet deze repository op privé** (GitHub → Settings → Danger Zone → Change visibility). Er staat je plan in. Sleutels en wachtwoorden horen alleen in Railway → Variables, nooit in GitHub.

## Instellen in Railway

1. **Database:** in je project → **Create** → **Database** → **PostgreSQL**. Ga daarna naar je website-dienst → **Variables** → **Add Variable Reference** → `DATABASE_URL` van de Postgres-dienst (staat hij er al, dan is dit klaar).
2. **Variabelen** (dienst → Variables → Raw Editor):
   ```
   APP_PASSWORD=een-lang-uniek-wachtwoord   # of een pincode, bijv. 4 cijfers
   XAI_API_KEY=
   EMAIL_HOST=imap.mail.me.com
   EMAIL_PORT=993
   EMAIL_USER=
   EMAIL_PASS=
   FINNHUB_API_KEY=
   ```
   - `EMAIL_USER` is de naam vóór **@icloud.com** (bijv. `jansen` voor jansen@icloud.com). Dat geldt ook als je mail op een eigen domein ontvangt via iCloud+: inloggen met het adres op je eigen domein lukt niet.
   - `EMAIL_PASS` is een **app-specifiek wachtwoord** (account.apple.com → Inloggen en beveiliging → App-specifieke wachtwoorden), niet je Apple-wachtwoord.
   - **Alleen mail aan één adres:** zet `EMAIL_TO=naam@jouwdomein.nl`. Dan haalt de site alleen berichten aan dat adres op (de mailserver filtert zelf op To, Cc en Delivered-To) en leest Grok de rest van je mailbox niet.
   - Of maak in iCloud Mail een map **Handelsplan** met een regel en zet `EMAIL_FOLDER=Handelsplan`.
   - Klik bovenaan op **Deploy** om de wijzigingen door te voeren.
3. **Inloggen:** open je site en log in met `APP_PASSWORD`.
4. Optioneel: `NTFY_TOPIC` (push naar je telefoon; zie Uitleg → *Meldingen op je telefoon*), `FRED_API_KEY` en `TWELVEDATA_API_KEY` (niet nodig: zonder sleutel komen dezelfde cijfers via FRED-csv en Yahoo), `INBOX_TOKEN` (transcripts vanaf je laptop), `EMAIL_SINCE_DAYS` (hoe ver terug bij de eerste keer, standaard 14), `XAI_MODEL` (standaard grok-4.7). Alles staat in `.env.example`.

Gebruik één exemplaar (geen replicas) en laat Serverless uit: de planner voor mail en koersen draait in de site zelf.

## Zie je of alles verbonden is?

- **Inlogscherm:** onderaan staat *Server verbonden* en *Database verbonden*. Staat er *APP_PASSWORD ontbreekt*, zet die dan in Railway → Variables.
- **Na inloggen:** de knop naast *Cijfers …* bovenin.
  - Groen: *Railway verbonden*.
  - Oranje: een koppeling werkt niet, bijvoorbeeld *E-mail niet verbonden*.
  - Rood: geen verbinding met de server of de database.
  - De stipjes erachter zijn database, AI, e-mail, marktdata en Finnhub.
- **Klik erop** voor de details per koppeling, met wat je moet aanpassen, bijvoorbeeld een verkeerd app-wachtwoord of een modelnaam die niet in je xAI-account staat. *Opnieuw testen* test meteen opnieuw.
- **Hoe vaak:** de database wordt elke minuut gecontroleerd. Mail, Grok en Finnhub worden hoogstens elke 5 minuten echt getest (inloggen bij IMAP, de modellijst van xAI, één koers bij Finnhub). Dat kost geen AI-tokens. Gaat een koppeling stuk of werkt hij weer, dan staat dat in het logboek (tab Post).

## Losse html (in Chrome openen, alles via Railway)

`handelsplan-2027.html` (bouwen met `python page/build_remote.py`) is één bestand dat je in Chrome opent.
- Er staat niets van je plan of je sleutels in: database, mail, Grok en koersen komen van je Railway-site.
- De eerste keer vul je het adres van je site in en `APP_PASSWORD`. Chrome bewaart daarna alleen dat adres en een inlogsleutel. Die sleutel is 30 dagen geldig (`TOKEN_DAYS`) en vervalt meteen als je `APP_PASSWORD` wijzigt.
- Bovenin zie je, net als op de site, of Railway verbonden is.

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
| `app/quotes.py` | Koersen van je volglijst (Finnhub, anders Yahoo; CoinGecko voor crypto) |
| `app/sources.py` | Databronnen zonder sleutel: FRED-csv, Yahoo Finance-grafieken, CoinGecko |
| `app/planstatus.py` | Planregels per positie toetsen (zelfde logica als de site), met *gedaan* en weer scherp zetten |
| `app/briefing.py` | De dagbriefing van Grok, met het verhaal, de vooruitblik en de vergelijking met de bronnen voor Vandaag |
| `app/extract.py` | Tekst uit documenten voor de inbox: pdf, Office, ondertitels, e-mail en afbeeldingen (via Grok) |
| `app/loginguard.py` | Bescherming van het inloggen: bekende apparaten en grenzen per adres, netwerk en samen |
| `app/updates.py`, `seed/updates/` | Inhoudelijke updates van plan en cijfers; elke update wordt één keer toegepast bij het starten, met een stap in Historie om terug te zetten |
| `app/health.py` | Verbindingstest per koppeling (`/api/connections`) |
| `app/scheduler.py`, `app/jobs.py` | Planner: mail en koersen elk kwartier, marktkoersen elk kwartier op werkdagen (07–23 u), macrocijfers om 07:20 en 23:20, briefing om 08:05 en 22:35 |
| `page/handelsplan.html` | De pagina; bij het bouwen (`page/build.py`) wordt hier `app/pages/index.html` van gemaakt. De link naar `app/static/shim.js` krijgt een versie (`?v=`), en `/static` wordt met `Cache-Control: no-cache` geserveerd, zodat een browser na een update nooit een oude versie blijft gebruiken |
| `seed/` | Je startplan en de cyclus-analyse; alleen ontbrekende onderdelen worden toegevoegd |

Persoonlijk educatief plan. Geen beleggingsadvies.
