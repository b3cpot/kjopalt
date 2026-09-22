# RaskBud: slik gjør du siden ekte

Uten oppsett kjører siden i **demo-modus**: kontoer, forespørsler og bilder lagres bare i nettleseren til den som bruker den. Det er fint for å teste, men kundene dine og du ser ikke hverandres data.

For å få ekte kunder trenger du en gratis database hos **Supabase** og et sted å legge ut siden, for eksempel **Netlify**. Det tar omtrent 20 minutter.

## 1. Lag databasen (Supabase)

1. Gå til supabase.com og lag en gratis konto.
2. Trykk **New project**. Velg region **Europe (Frankfurt eller Stockholm)**, og skriv ned passordet.
3. Når prosjektet er klart: gå til **SQL Editor**, trykk **New query**, lim inn hele `supabase-oppsett.sql` og trykk **Run**.
4. Gå til **Project Settings > API** og kopier:
   - **Project URL**
   - **anon public**-nøkkelen (ikke `service_role`, den skal aldri inn på nettsiden)

## 2. Koble siden til databasen

Åpne `index.html` i en teksteditor (Notisblokk holder). Finn `CONFIG` øverst i skriptet og fyll inn:

```js
const CONFIG = {
  supabaseUrl: "https://dittprosjekt.supabase.co",
  supabaseAnonKey: "eyJhbGciOi...",
  demoAdminEmail: "admin@raskbud.no",
  receiver: ["RaskBud v/ Ditt Navn", "Gateadresse 1", "1234 Sted"]
};
```

`receiver` er adressen kundene sender pakkene til. Den vises på adresselappen.

## 3. Legg ut siden (Netlify)

1. Gå til app.netlify.com/drop
2. Dra hele `raskbud`-mappen inn i vinduet.
3. Du får en adresse som `raskbud-123.netlify.app`. Eget domene (raskbud.no) kan kobles til under **Domain settings**.

I Supabase: gå til **Authentication > URL Configuration** og legg inn Netlify-adressen din under **Site URL**, så lenkene i bekreftelses-e-postene går til riktig sted.

## 4. Gjør deg selv til admin

1. Gå til siden din og registrer deg med din egen e-post.
2. I Supabase > SQL Editor, kjør (med din e-post):

```sql
update public.profiles set is_admin = true
  where id = (select id from auth.users where email = 'din@epost.no');
```

3. Logg ut og inn igjen. Nå ser du **Admin** i menyen.

## 5. Spillsøk med bilder og strekkodeskanner

Når kunden skriver «zelda» eller «sony», får de en liste med bilder. De kan også skanne strekkoden bak på esken med mobilkameraet.

**Hva som er gratis og hvor det kommer fra:**

| Del | Hentes fra | Pris |
|---|---|---|
| Skanneren i mobilen | ZXing (åpen kildekode, lastes automatisk) | Gratis |
| Spill med boksbilde | TheGamesDB (RAWG som reserve) | Gratis |
| Konsollbilder | Wikipedia | Gratis |
| Strekkode → navn på spillet | UPCitemdb | Gratis, 100 oppslag per dag |

Alt du slår opp lagres i din egen database (tabellen `barcodes`). Samme strekkode slås aldri opp to ganger, så databasen blir bedre for hver skanning.

### Skaff nøklene

1. **TheGamesDB:** lag en bruker på forums.thegamesdb.net og be om en API-nøkkel i forumet. Skriv at det er for en liten norsk innkjøpsbutikk, og spør om det er greit å bruke den kommersielt.
2. **RAWG (reserve):** lag en gratis bruker på rawg.io/apidocs og hent nøkkelen. Den er gratis for bedrifter opptil 20 000 søk i måneden, så lenge siden lenker til RAWG (det gjør bunnteksten allerede).
3. **UPCitemdb:** trenger ingen nøkkel.

Du trenger bare én av de to første for å komme i gang.

### Legg inn funksjonen i Supabase

1. Kjør `supabase-oppsett.sql` på nytt (den lager tabellene `barcodes` og `lookup_cache`).
2. I Supabase: gå til **Edge Functions**, velg **Deploy a new function** og **Via Editor**.
3. Kall funksjonen `lookup`, lim inn hele innholdet i `supabase/functions/lookup/index.ts` og trykk **Deploy**.
4. Gå til **Edge Functions > Secrets** og legg inn:
   - `TGDB_KEY` = nøkkelen fra TheGamesDB
   - `RAWG_KEY` = nøkkelen fra RAWG

Nettsiden finner funksjonen av seg selv når Supabase-nøklene står i `CONFIG`.

### Lær opp strekkoder

Finnes ikke en strekkode, skriver kunden navnet selv. I Admin ser du da **«Lær koden: lagre den som …»** under tingen. Trykk på den når du har sjekket at navnet stemmer, så kjenner siden igjen koden neste gang.

### Kamera

Kameraet virker bare på en ekte nettside med https (Netlify gir deg det automatisk). Kunden må trykke **Tillat** når mobilen spør. Sier de nei, kan de ta et bilde av strekkoden eller skrive inn tallene i stedet.

## Slik fungerer det i hverdagen

1. Kunden legger inn spill, konsoller osv. med bilder og sender inn. Status: **Venter på bud**.
2. Du åpner forespørselen i Admin, ser på bildene, setter pris på hver ting og trykker **Send bud til kunden**. Pris 0 betyr at du ikke vil kjøpe den tingen.
3. Kunden velger hva de vil selge og godtar. Status: **Skal sendes**.
4. Du sender fraktetikett på e-post (se under). Når pakken kommer: **Merk som mottatt**.
5. Stemmer alt, betal til Vipps eller konto og trykk **Merk som utbetalt**. Stemmer noe ikke, send et justert bud.

Pokémon-kort i bulk har fast pris og går rett til **Skal sendes**. Prisene endrer du under **Admin > Kortpriser**.

## Det som ikke er automatisk ennå

- **E-postvarsler.** Supabase sender bare e-post ved registrering. Kunden ser budet under Min konto, men får ikke e-post når du sender bud. Neste steg: en Supabase Edge Function med Resend (gratis opptil 3000 e-poster i måneden).
- **Fraktetiketter.** Siden lager en adresselapp med referanse, men ikke en ekte Posten/Bring-etikett. Lag etiketten hos Bring (bring.no, Mybring bedriftskonto) og send den til kunden.
- **Utbetaling.** Du betaler selv i Vipps eller nettbanken. Siden holder bare oversikt.

## Om bildene

Bildene ligger i Supabase Storage med tilfeldige, ugjettelige adresser. De er ikke listet noe sted, men den som har lenken kan se bildet. Gratisplanen har 1 GB lagring, som holder til rundt 5000 bilder.
