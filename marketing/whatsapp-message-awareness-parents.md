# 📣 WhatsApp Message — Parent & Student Awareness (Pre-Implementation)

Ready-to-send WhatsApp awareness message for an institute that is **planning**
to introduce ClassPass but has **not yet implemented it**. It informs parents
and students about the upcoming system, what it will do for them, and what it
will cost (**Rs. 150/=** one-time for the QR laminated ID card).

Because the system is not live yet, this message deliberately:

- speaks in **future tense** ("we are introducing…", "you will receive…"),
- contains **no portal URL** (no tenant subdomain exists yet),
- ends by inviting questions rather than giving login instructions.

Uses WhatsApp formatting (`*bold*`) — copy the text inside the code blocks
directly into WhatsApp so the formatting renders.

> Replace `[Institute Name]` and the contact number before sending.

---

## 🇬🇧 English Version

```
📢 *[Institute Name] — Exciting News!*

Dear Parents & Students,

We are planning to introduce *ClassPass* — a smart attendance & payment system — to our institute soon. Here's what it will bring you 👇

━━━━━━━━━━━━━━━

✨ *What will change?*

🪪 Every student will receive a personal *QR ID card* (laminated & durable)
✅ Attendance will be marked with *one quick scan* at the classroom — no more registers
📲 Parents will receive an *SMS the moment your child arrives* at class
💰 Every fee payment will be confirmed by *SMS + a printed receipt*
📱 Attendance & payment records will be available to view *anytime online*

━━━━━━━━━━━━━━━

👨‍👩‍👧 *Why we are doing this*

🗓️ You will always know your child attended class — no more uncertainty
🔍 Complete transparency in fee payments
🔒 All records kept private and secure
⏱️ Less time on paperwork — more time for teaching

━━━━━━━━━━━━━━━

💳 *What will it cost you?*

The only charge is for the student's QR ID card:
▪️ *Rs. 150/= only* — one-time payment
▪️ Laminated card — lasts the whole year

━━━━━━━━━━━━━━━

We will inform you of the starting date and card issuing details soon.

❓ Any questions? Feel free to ask us!
☎️ 07X XXX XXXX

Thank you!
*[Institute Name]*
```

---

## 🇱🇰 Sinhala Version

```
📢 *[ආයතනයේ නම] — සතුටුදායක ආරංචියක්!*

හිතවත් දෙමාපියන් සහ සිසුන්,

අපගේ ආයතනයට ළඟදීම *ClassPass* ස්මාර්ට් පැමිණීම් සහ ගෙවීම් පද්ධතිය හඳුන්වා දීමට අප සූදානම් වෙමු. එයින් ඔබට ලැබෙන පහසුකම් 👇

━━━━━━━━━━━━━━━

✨ *අලුතෙන් සිදුවන්නේ මොනවාද?*

🪪 සෑම සිසුවෙකුටම තමන්ගේම *QR ID කාඩ්පතක්* ලැබේ (laminated — කල් පවතී)
✅ පන්තියේදී *එක scan එකකින්* පැමිණීම සටහන් වේ — කොළ ලේඛන අවශ්‍ය නැහැ
📲 දරුවා පන්තියට *පැමිණි විගසම දෙමාපියන්ට SMS* පණිවිඩයක් ලැබේ
💰 සෑම ගාස්තු ගෙවීමක්ම *SMS සහ මුද්‍රිත රිසිට්පතකින්* තහවුරු වේ
📱 පැමිණීම් සහ ගෙවීම් විස්තර *ඕනෑම වේලාවක online* බලාගත හැකි වේ

━━━━━━━━━━━━━━━

👨‍👩‍👧 *අප මෙය සිදු කරන්නේ ඇයි?*

🗓️ දරුවා පන්තියට සහභාගී වූ බව සැකයකින් තොරව සැමවිටම දැනගත හැක
🔍 ගාස්තු ගෙවීම්වල සම්පූර්ණ විනිවිදභාවය
🔒 සියලු තොරතුරු පුද්ගලික සහ ආරක්ෂිතයි
⏱️ ලිපිකරු වැඩවලට යන කාලය අඩුයි — ඉගැන්වීමට වැඩි කාලයක්

━━━━━━━━━━━━━━━

💳 *ඔබට වැය වන්නේ කීයද?*

අය කරන එකම ගාස්තුව සිසුවාගේ QR ID කාඩ්පත සඳහා පමණයි:
▪️ *රු. 150/= පමණයි* — එක් වරක් පමණක් ගෙවීම
▪️ Laminated කාඩ්පත — වසර පුරාම කල් පවතී

━━━━━━━━━━━━━━━

පද්ධතිය ආරම්භ කරන දිනය සහ කාඩ්පත් නිකුත් කිරීමේ විස්තර ළඟදීම දැනුම් දෙන්නෙමු.

❓ ප්‍රශ්න තිබේද? අපෙන් විමසන්න!
☎️ 07X XXX XXXX

ස්තූතියි!
*[ආයතනයේ නම]*
```

---

## 📝 Notes

- **When to use which message**:
  | Stage | Message |
  |---|---|
  | Selling ClassPass to an institute | [whatsapp-promotional-message](./whatsapp-promotional-message.md) |
  | Institute preparing parents *before* implementation | this file |
  | System live — onboarding students & parents | [whatsapp-message-students-parents](./whatsapp-message-students-parents.md) |
- **No portal URL**: the tenant subdomain doesn't exist until the institute is
  onboarded ([multi-tenant-subdomain-access](../architecture/multi-tenant-subdomain-access.md)),
  so this message promises online access without linking anywhere. Once live,
  switch to the students & parents onboarding message, which includes the URL.
- **Cost framing**: the Rs. 150/= card charge is presented under "What will it
  cost you?" and explicitly called the *only* charge, answering the question
  parents will ask first.
- **Feature claims** are grounded in the wiki: scan-to-mark attendance
  ([attendance-module](../modules/attendance-module.md)), parent SMS on
  attendance and payments ([notification-service](../modules/notification-service.md)),
  printed receipts ([receipt-printing](../modules/receipt-printing.md)), and
  online attendance/payment history ([student-guide](../guides/student-guide.md)).
