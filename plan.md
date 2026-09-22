# Spillpant — plan mot lansering

Sist oppdatert: 22. september 2026. Mål: liste for ekte kunder om ~2 dager.

---

## 0. Rett en misforståelse: admin-panelet finnes allerede

Under er det ikke i planen som "å bygge", fordi det er bygget og testet:

- **Admin-panel** — oversikt med "Trenger bud" / "Venter på kunden" / "Skal sendes" / "Mottatt, må betales", søk, filtre, prisskjema per ting, internt notat, "lær opp strekkode"-knapp, kortpris-side.
- **Hele kjøpsflyten** — kunde legger inn ting med bilder → admin setter pris → kunde godtar/avslår helt eller delvis → fraktetikett → admin merker mottatt → admin betaler ut.
- **Database og sikkerhetsregler** — kjørt på det ekte Supabase-prosjektet (`kjopalt`, eu-north-1), ikke bare lokalt.
- **Sikkerhetstest med agent, allerede kjørt** — 16 automatiserte forsøk mot den ekte databasen med midlertidige testbrukere (slettet etterpå): en kunde som prøver å forfalske en pris, gjøre seg selv til admin, endre status selv, sende inn direkte forbi kodén, svare på et bud to ganger, lese en annen kundes forespørsel, eller lese admins private notater. Alle 16 ble stanset av databasereglene. Detaljer i seksjon 5.
- **Strekkodeskanning og spillsøk med bilder** — kamera + bildeopplasting, ZXing-skanner, oppslag mot UPCitemdb (strekkoder) og TheGamesDB/RAWG (spillnavn og bilder), med egen database som lærer seg strekkoder den har sett før.
- **Nettsiden er på nett** — github.com/b3cpot/kjopalt → GitHub Pages på `https://b3cpot.github.io/kjopalt/`, koblet til det ekte Supabase-prosjektet (ikke demo-modus).

Det som gjenstår er reelt nok arbeid til to dager, men det er oppsett, nøkler, innhold og siste sjekker — ikke bygging av kjernefunksjoner fra bunnen.

---

## 1. Dag 1 (i dag): nøkler, adresse, og gjør meg til admin

Disse blokkerer alt annet, så de går først.

- [x] **Admin-e-post mottatt:** `altkjop@gmail.com`. Kontoen fantes ikke ennå, så jeg har satt opp databasen til å gjøre den til admin automatisk i det øyeblikket du registrerer deg på siden med denne e-posten — du trenger ikke si ifra på nytt, bare registrer deg.
- [x] **Returadresse satt:** Kjøpalt, Atomveien 20K, 1777 Halden. Dette er adressen som skal stå på pakken kunden sender *til deg* etter at de har godtatt et bud. Verifisert på fraktetiketten i en full test.
- [ ] **TheGamesDB-nøkkel.** Registrer deg på forums.thegamesdb.net og be om en API-nøkkel. Skriv at det er for en liten norsk innkjøpsbutikk, og spør om kommersiell bruk er greit.
- [ ] **RAWG-nøkkel (reserve/supplement).** Gratis konto på rawg.io/apidocs, tar under to minutter. Gratis for bedrifter opptil 20 000 søk/måned så lenge siden lenker til RAWG (det gjør den allerede i bunnteksten).
- [ ] Så snart én av de to nøklene finnes: jeg legger dem inn i Supabase → Edge Functions → Secrets (`TGDB_KEY`, `RAWG_KEY`). Ingen kodeendring trengs, bare nøkkelen.
- [ ] **Navn — utsatt.** "Spillpant" var feil retning (dere kjøper, det er ikke pant). "Loftet" og "Skrinet" er begge sjekket opptatt/vurdert utilstrekkelig. Vi lander navnet senere; nettsiden kjører videre under det tekniske navnet "Kjøpalt" (fra GitHub-repoet) inntil videre, og merkevaren byttes når navnet er bestemt.

**Slik fungerer det, bekreftet riktig forstått:** Kunden sender inn ting → du gir et bud → kunden godtar → siden gir kunden et referansenummer og din adresse på etiketten → kunden sender pakken selv → du sjekker varene når de kommer → du betaler ut. Ingen kobling til Posten API trengs ennå — riktig prioritert til senere.

## 2. Dag 1: sikkerhetsgjennomgang med agent (utover det som allerede er kjørt)

Testen jeg allerede har kjørt dekker databasereglene (hvem kan lese/skrive hva). Status nå:

- [x] **Supabase advisor-sjekk på nytt.** Kjørt 22. sep. De eneste varslene er forventede (funksjonene `create_submission`/`respond_offer`/`add_message` skal være kallbare av innloggede kunder — de sjekker identitet internt — og `lookup_cache` har bevisst ingen policyer siden bare serverfunksjonen skal røre den). Ingen reelle hull funnet.
- [x] **Last opp-grenser for bilder.** Satt: 8 MB maks per fil, kun JPEG/PNG/WebP godtas, på Storage-bøtten `photos`.
- [x] **Rate-limit på `lookup`-funksjonen.** Lagt til: maks 30 kall per IP per minutt, håndheves i databasen (ikke bare i funksjonen, så den kan ikke omgås). Testet med 50 samtidige kall fra automatisert agent — nøyaktig 30 slapp gjennom, resten ble avvist med en norsk feilmelding, ingen dobbelttelling. Rullet ut som versjon 2 av funksjonen.
- [ ] **Fullstendig ende-til-ende-test på den ekte, live siden** (ikke bare lokalt simulert som til nå): opprett konto → legg inn en ting med bilde → logg inn som admin → gi bud → logg inn som kunde → godta → merk mottatt → betal ut. Venter på nettverkstilgang, se punkt 4.
- [ ] **Prøv å lure systemet på den live siden**, ikke bare i simulering: logg inn som to ekte testbrukere i to faner og gjenta forfalskningsforsøkene fra den tidligere testen, denne gangen mot den offentlige URL-en og med ekte nettverkstrafikk, ikke direkte mot databasen. Venter på punkt 4.
- [ ] **Sjekk at e-postbekreftelse faktisk fungerer** fra domenet siden ligger på (GitHub Pages eller Vercel), ikke bare at Supabase sender e-posten.

## 3. Vercel — koblet til og bekreftet live

**Løst.** Vercel-tilkoblingen fungerte etter at du koblet den til på nytt fra claude.ai-siden (ikke bare fra Vercels eget grensesnitt — det var forskjellen).

- [x] Prosjektet `kjopalt` er koblet til `b3cpot/kjopalt` på GitHub og bygger automatisk fra `main`.
- [x] Produksjons-URL: **`kjopalt.vercel.app`**. Bekreftet: status 200, riktig innhold, riktig Supabase-tilkobling (ikke demo-modus).
- [x] Bekreftet at den bygger på nytt for hver push — nyeste commit (sikkerhetsoppdateringene fra i dag) var allerede i produksjon.
- [ ] Bestem hvilken av GitHub Pages (`b3cpot.github.io/kjopalt`) og Vercel (`kjopalt.vercel.app`) som er den "ekte" adressen kundene skal bruke — de er identiske nå, så velg ut fra smak. Vercel er enklere å koble et eget domene til senere.
- [ ] Om dere vil ha et eget domene pekende på Vercel: sett det opp når domenet er kjøpt (navn ikke landet ennå — se punkt 6).

## 4. Nettverkstilgang jeg trenger fra deg

Sandkassen min er blokkert fra to adresser jeg trenger for å teste selv, i stedet for at du må gjøre alt manuelt:

- `*.supabase.co`
- `b3cpot.github.io` (og `*.vercel.app` når den er satt opp)

Legg disse til i de tillatte nettverksdomenene for denne samtalen, så kan jeg kjøre hele test-løypa over selv og vise deg akkurat hva som funker og ikke.

## 5. Hva som allerede er verifisert (for referanse)

Kjørt direkte mot den ekte Supabase-databasen `kjopalt`, med midlertidige testbrukere som ble slettet etter testen:

| # | Test | Resultat |
|---|---|---|
| 1 | Kunde sender falsk pris (99 999 kr) på en ting | Ignorert — ekte pris (250 kr) brukt |
| 2 | Kunde prøver å gjøre seg selv til admin | Blokkert |
| 3 | Kunde prøver å endre status/pris direkte i databasen | Blokkert, ingen endring |
| 4 | Kunde prøver å sette inn en forespørsel direkte forbi funksjonen | Blokkert |
| 5 | Kunde svarer på et bud som ikke finnes ennå | Blokkert med feilmelding |
| 6 | Kunde prøver å skrive en strekkode selv | Blokkert |
| 7 | Andre kunde prøver å se den første kundens forespørsler | 0 rader, ser ingenting |
| 8 | Andre kunde prøver å sende melding på noen andres forespørsel | Blokkert |
| 9 | Admin gir bud, notat og lærer opp en strekkode | Fungerer |
| 10 | Kunde godtar delvis (én av to ting) | Riktig sum, riktig status |
| 11 | Kunde prøver å svare på samme bud to ganger | Blokkert |
| 12 | Kunde prøver å lese admins private notater | 0 rader |
| 13 | Ikke-innlogget besøkende leser kortpriser (skal fungere) | Fungerer |
| 14 | Ikke-innlogget besøkende leser andres forespørsler | 0 rader |
| 15 | Ikke-innlogget besøkende prøver å sende inn en forespørsel | Blokkert |

Se punkt 2 for hva som gjenstår utover dette.

## 6. Det som bevisst er utsatt til etter lansering

Ikke kritisk for å ta imot de første kundene:

- E-postvarsel når admin sender et bud (kunden ser det når de logger inn, men får ikke e-post ennå)
- Ekte Posten/Bring-fraktetiketter (siden lager i dag en adresselapp med referansenummer; ekte etikett lages manuelt hos Bring og sendes på e-post)
- Automatisk utbetaling til Vipps/konto (admin betaler manuelt og trykker "merk som utbetalt")
- Bilde-gjenkjenning fra forsidebilde av spillet (kun strekkode og tekstsøk er med nå)
