# 📣 WhatsApp Promotional Message — ClassPass

Ready-to-send WhatsApp promotional copy for ClassPass, in English and Sinhala.
This version features **QR laminated cards** (instead of NFC) for institutes
that prefer QR-based student identification.

Uses WhatsApp formatting (`*bold*`) — copy the text inside the code blocks
directly into WhatsApp so the formatting renders. The copy is structured in
short blocks with blank lines between them so it stays easy to scan on a
mobile screen.

> Replace `yourinstitute.classpass.lk` and the contact number before sending.

---

## 🇬🇧 English Version

```
🎓 *ClassPass*
Smart Attendance & Fee Management for Your Institute

Still marking attendance on paper?
It's time to go smart 👇

━━━━━━━━━━━━━━━

✅ *Scan & Go Attendance*
Each student gets a durable QR laminated ID card. One quick scan — attendance marked instantly.

📲 *Instant Parent SMS*
Parents get an SMS the moment their child arrives at class, and when fees are paid.

💰 *Easy Fee Management*
Collect class fees, track payments and print receipts in seconds.

📊 *Real-Time Reports*
Attendance and income analytics, anytime, on any device.

🌐 *Your Own Branded Portal*
yourinstitute.classpass.lk

━━━━━━━━━━━━━━━

⭐ *Why institutes choose ClassPass*

🚀 No expensive hardware — any smartphone camera can scan
💳 Low-cost, long-lasting laminated QR cards
🇱🇰 Made for Sri Lankan institutes — SMS in Sinhala, Tamil & English
🔒 Secure cloud platform — your data is always safe
🏫 Scales from one class to multi-branch institutes

━━━━━━━━━━━━━━━

📞 Book your *FREE demo* today!
☎️ 07X XXX XXXX
🌐 www.classpass.lk
```

---

## 🇱🇰 Sinhala Version

```
🎓 *ClassPass*
ඔබේ ආයතනයට ස්මාර්ට් පැමිණීම් සහ ගාස්තු කළමනාකරණය

තවමත් කොළවල පැමිණීම ලකුණු කරනවාද?
දැන් ස්මාර්ට් වෙන්න කාලයයි 👇

━━━━━━━━━━━━━━━

✅ *Scan කරන්න — ඉවරයි!*
සෑම සිසුවෙකුටම කල් පවතින QR laminated ID කාඩ්පතක්. එක scan එකකින් පැමිණීම ක්ෂණිකව සටහන් වේ.

📲 *දෙමාපියන්ට ක්ෂණික SMS*
දරුවා පන්තියට පැමිණි විගස සහ ගාස්තු ගෙවූ විට දෙමාපියන්ට SMS ලැබේ.

💰 *පහසු ගාස්තු කළමනාකරණය*
පන්ති ගාස්තු එකතු කිරීම, ගෙවීම් පසුවිපරම සහ රිසිට්පත් මුද්‍රණය තත්පර කිහිපයකින්.

📊 *තත්‍ය කාලීන වාර්තා*
පැමිණීම් සහ ආදායම් විශ්ලේෂණ ඕනෑම වේලාවක, ඕනෑම උපකරණයකින්.

🌐 *ඔබේම නමින් වෙබ් පෝර්ටලයක්*
yourinstitute.classpass.lk

━━━━━━━━━━━━━━━

⭐ *ආයතන ClassPass තෝරාගන්නේ ඇයි?*

🚀 මිල අධික උපකරණ අවශ්‍ය නැහැ — ඕනෑම ස්මාර්ට්ෆෝන් කැමරාවකින් scan කළ හැක
💳 අඩු වියදම්, කල් පවතින laminated QR කාඩ්පත්
🇱🇰 ශ්‍රී ලාංකික ආයතන සඳහාම නිර්මාණය කළ — සිංහල, දෙමළ සහ ඉංග්‍රීසි SMS
🔒 ආරක්ෂිත cloud පද්ධතියක් — ඔබේ දත්ත සැමවිටම සුරක්ෂිතයි
🏫 තනි පන්තියක සිට ශාඛා කිහිපයක් දක්වා පුළුල් කළ හැක

━━━━━━━━━━━━━━━

📞 අදම *නොමිලේ demo* එකක් වෙන්කරගන්න!
☎️ 07X XXX XXXX
🌐 www.classpass.lk
```

---

## 📝 Notes

- **QR laminated cards**: this copy is tailored for institutes that prefer
  QR-based laminated ID cards over NFC cards. The scanning flow is otherwise
  the same — the card checker scans the student's card with the PWA on any
  smartphone ([attendance-module](../modules/attendance-module.md),
  [card-inventory](../modules/card-inventory.md)).
- **Other feature claims** are grounded in the wiki: parent SMS on attendance
  and payments ([notification-service](../modules/notification-service.md)),
  Sinhala/Tamil unicode SMS support ([sms-credit-billing](../modules/sms-credit-billing.md)),
  fee collection and receipt printing ([fee-management](../modules/fee-management.md),
  [receipt-printing](../modules/receipt-printing.md)), and branded tenant
  subdomains ([multi-tenant-subdomain-access](../architecture/multi-tenant-subdomain-access.md)).
- **Mobile readability**: each feature is a bold one-line headline followed by
  a single short sentence, with blank lines between blocks and `━━━` dividers
  separating the three sections (features / why us / contact). This keeps the
  message skimmable on a phone screen.
- **Broadcast tip**: personalise the first line with the recipient's institute
  name when sending via broadcast lists for better response rates.
