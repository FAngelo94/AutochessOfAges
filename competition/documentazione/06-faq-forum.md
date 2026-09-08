# FAQ — risposte ufficiali dei manager sul forum Devpost

Thread selezionati dalle tre pagine di elenco discussioni salvate in
`competition/pages-of-revenuewcat/discussions/` e recuperati dal forum, scelti perché rilevanti
per **un gioco mobile Android, sviluppatore singolo adulto, non studente, progetto preesistente
mai pubblicato**.

Le risposte marcate **[Manager]** sono ufficiali. Le risposte del forum non sostituiscono il
regolamento: in caso di conflitto prevale il regolamento (Sezione 11).

---

## Eleggibilità dell'app

### Un'app già in Google Play open testing / public beta è ancora eleggibile?

**Sì per l'open testing precedente, ma la beta non basta come release.** Due risposte, apparentemente
in tensione, che in realtà dicono la stessa cosa da due lati:

> **[Manager — Perttu Lähteenlahti]** *"Your app is eligible. Google Play Open Testing does not
> count as a public release for Shipaton. As long as your app's first production release on an
> eligible app store happens during the submission period."*
> — [thread 44652](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44652-eligibility-of-an-app-that-was-in-google-play-open-testing-before-the-submission-period)

> **[Manager — Jaewoong Eum]** *"For Shipaton, Google Play Open Testing / public beta does not
> count as a public release, even if anyone can download it. To qualify for the general categories,
> the app needs to have its first production release on an eligible app store during the Shipaton
> submission period. A testing-track build alone isn't enough."*
> — [thread 45132](https://revenuecat-shipaton-2026.devpost.com/forum_topics/45132-google-play-public-beta-eligibility) (copia locale in `discussions/discussion-details/`)

**Conseguenza pratica:** un closed/open testing avviato adesso non brucia l'eleggibilità, ma **non
è sufficiente**: serve la **release in produzione** entro il 30 settembre.

### Un progetto/prototipo che esisteva già è eleggibile?

> **[Manager — Jaewoong Eum]** *"Yes, it's still eligible as long as the app has not previously
> been released on an eligible app store. Having an existing idea, prototype, or backend project
> does not disqualify you."*
> — [thread 44729](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44729-never-successfully-published-system)

> **[Manager — Charlie Chapman]** su un prototipo solo-web trasformato in app mobile: *"Yep! This
> would be eligible as long as the only existing version was the website."*
> — [thread 44677](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44677-eligibility-confirmation-existing-web-only-prototype-and-substantially-new-ios-app)

**Rilevante:** Autochess Of Ages esiste da mesi come repo Godot e non è mai stato pubblicato su
nessuno store → eleggibile.

### Portare su una nuova piattaforma un'app già pubblicata?

> **[Manager — Rhys Kentish]**, alla domanda se una versione iOS nuova di un'app Android già
> pubblicata a luglio fosse eleggibile: *"To answer your first question, no, unfortunately that
> wouldn't be eligible."* Alla domanda se fosse eleggibile un'app **nuova** basata su un'idea
> simile ma con branding, bundle ID, scheda store e user flow sostanzialmente diversi: *"yes that
> would be eligible!"*
> — [thread 44609](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44609-eligibility-new-platform-release-and-new-app-with-a-different-user-flow)

### Quale data conta, approvazione o pubblicazione?

> **[Manager — Austin Blake]** *"Shipaton officially kicked off at midnight JST (Japan Standard
> Time). As long as your app goes live after that time - you're eligible!"*
> — [thread 44718](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44718-submission-period)

Conta il **go-live**, non l'approvazione dello store.

---

## RevenueCat e monetizzazione

### RevenueCat deve essere già presente nella prima versione pubblicata?

**No.**

> **[Manager — Perttu Lähteenlahti]** *"As long as your app's first public release on an eligible
> app store occurs during the Shipaton submission window, and before you submit to Devpost the app
> has been updated to integrate RevenueCat with a qualifying in-app purchase (or RevenueCat Ads),
> your project is eligible. The RevenueCat integration does not need to be present in the very
> first public store version."*
> — [thread 44759](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44759-revenuecat-sdk)

**Conseguenza pratica enorme per pianificare:** si può pubblicare prima la build di gioco e far
arrivare l'integrazione RevenueCat con un aggiornamento, purché sia in produzione prima della
submission su Devpost. Riduce il rischio di sforare per colpa della review.

### Il test store di RevenueCat basta?

> **[Manager — Rhys Kentish]** *"you can use RevenueCat's test store and that would satisfy the
> criteria."* — nel contesto di un partecipante Next Gen che non voleva pubblicare sullo store.
> — [thread 44777](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44777-should-the-app-be-product-level-or-mvp-level)

⚠️ Da leggere con cautela: per le **categorie generali** l'app deve comunque essere live sullo
store, e il Grand Prize usa i **ricavi reali riportati in RevenueCat** per costruire la shortlist.
Il test store risolve il requisito "usa RevenueCat", non la crescita.

### MVP o prodotto rifinito?

> **[Manager — Rhys Kentish]** *"there's no criteria saying you have to have a login system or any
> specific feature, you only must incorporate RevenueCat in some way. MVP vs more fleshed out app
> is your choice but usually more complete apps do better!"*
> — [thread 44777](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44777-should-the-app-be-product-level-or-mvp-level)

---

## Store, account e pubblicazione

### Basta il solo Google Play?

> **[Manager — Perttu Lähteenlahti]** *"'Ship a brand-new app to the App Store, Google Play Store,
> or the Samsung Galaxy Store', so a Play Store-only release is enough. Some sponsor award
> categories might have requirements on which stores you need to target to be eligible, but that
> only applies to those categories."*
> — [thread 44297](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44297-play-store-or-app-store)

E sui tempi di review, **[Manager — Rhys Kentish]**: *"As long as it's live before September 30th
then you're good :)"*
— [thread 44594](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44594-public-on-google-play-store)

### Si può pubblicare su più store con la stessa app? Si può condividere un account sviluppatore?

> **[Manager — Austin Blake]** *"No problem with using the same account! And yes, can publish into
> as many or as few stores as you'd like. You're also eligible to compete for as many simultaneous
> categories as you qualify for."*
> — [thread 44918](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44918-question-about-app-store-accounts-and-publishing-on-multiple-platforms)

> **[Manager — Jaewoong Eum]**, sull'usare l'account Play di un amico: *"Yes, you can publish
> through your friend's Google Play developer account. However, since the project needs to be
> verified as your own work, we may ask you to provide proof during the verification process. The
> easiest way would be to have your friend add your Google account as a user for that specific app
> in Play Console."*
> — [thread 45011](https://revenuecat-shipaton-2026.devpost.com/forum_topics/45011-google-play-store-suggestion-managers-of-hackathons-and-anyone-who-know-answer)

⚠️ Ma pubblicare sullo store **non è aggirabile**:

> **[Manager — Jaewoong Eum]** *"If the app isn't actually published on the App Store or Google
> Play, it won't meet the eligibility requirements."*
> — [thread 44857](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44857-play-store-account-creation)

### I 12 tester di Google Play

Il requisito Google (account sviluppatore personali aperti dopo novembre 2023): **12 tester per 14
giorni consecutivi** in closed testing prima di poter accedere alla produzione. Sul forum ci sono
thread di scambio tester tra partecipanti, e la risposta ufficiale indirizza a Discord:

> **[Manager — Jaewoong Eum]** *"There's a #looking-for-google-play-tester channel on our Discord.
> Please share your app in the channel."*
> — [thread 45080](https://revenuecat-shipaton-2026.devpost.com/forum_topics/45080-shipaton-android-test-swap-need-12-closed-testers-for-blood-pact)

Nel thread, i partecipanti si offrono a vicenda test reali (installazione + feedback), non install
fittizi.

---

## Submission e categorie

### Si può concorrere a più categorie con la stessa app?

> **[Manager — Rhys Kentish]** *"Hi Abbas, you can participate in multiple categories when you
> submit your submission!"*
> — [thread 44452](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44452-is-it-possible-that-i-can-apply-with-one-app-in-mulitple-categories)

Confermato anche da Austin Blake (sopra). Unica restrizione: una sola categoria Influencer per
progetto.

### Si possono presentare più app?

> **[Manager — Jaewoong Eum]** *"Yes! You're welcome to submit more than one app during the
> hackathon. Each app should be submitted as a separate project on Devpost."*
> — [thread 44341](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44341-can-we-submit-more-than-1-project-app)

> **[Manager — Rhys Kentish]** aggiunge: *"We do recommend building one app however and making it
> the best you can"*.

### Dove si caricano icona e screenshot?

> **[Manager — Jaewoong Eum]** *"You can upload them under Project Media → Image Gallery. That's
> the right place for the app icon and screenshots."*
> — [thread 44923](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44923-question-about-the-app-icon-and-screenshots-upload)

### Le dimensioni dello screenshot sono vincolanti?

> **[Manager — Jaewoong Eum]**, a chi ha un'app solo iPad e non può rispettare 1179×2556: *"Hey,
> for sure, you can submit the best solution for your product."*
> — [thread 45131](https://revenuecat-shipaton-2026.devpost.com/forum_topics/45131-screenshot-dimensions)

Per un gioco Android in portrait, 1179×2556 è comunque un formato sensato: conviene rispettarlo.

### Build in public restando in stealth?

> **[Manager — Perttu Lähteenlahti]** *"Yes. The Build in Public category is about documenting your
> journey, not revealing every detail of your app. You're welcome to stay in stealth mode and share
> things like your progress, lessons learned, challenges, decisions, wins, and failures without
> showing the product itself. […] Your final hackathon submission will still need to showcase the
> app for judging, but during development you can absolutely choose how much of the product you
> reveal."*
> — [thread 44654](https://revenuecat-shipaton-2026.devpost.com/forum_topics/44654-can-we-do-build-in-public-without-showing-the-app)

### Vincitore che non può viaggiare o non parla bene inglese?

> **[Manager — Charlie Chapman]** *"We'll still ship prizes out if you cannot make it in person!"*
> — [thread 43972](https://revenuecat-shipaton-2026.devpost.com/forum_topics/43972-what-happens-if-i-m-the-winner)

Resta però l'obbligo del regolamento: **tutti i materiali della submission devono essere in
inglese** o accompagnati da traduzione inglese.

---

## Thread esaminati e scartati come non pertinenti

Riguardano il Next Gen Award (studenti: licenza open source da usare, verifica email accademica,
minori di 18 anni, checkbox di store release bloccante), riscatto di perk specifici (Paddle,
Mobbin, OpenRouter, Junie), eleggibilità geografica di paesi specifici (Russia, Quebec, Brasile),
problemi di invito ai team, app puramente web, e sondaggi informali tra partecipanti. Gli elenchi
completi restano in `discussions/mainpages1-3.html`.
