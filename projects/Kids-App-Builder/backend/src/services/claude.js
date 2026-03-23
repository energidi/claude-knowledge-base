import Anthropic from '@anthropic-ai/sdk'

const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY })

const GENDER_FORMS = {
  male:    { you: 'אתה', want: 'רוצה', built: 'בנית', ready: 'מוכן', great: 'מצוין' },
  female:  { you: 'את',  want: 'רוצה', built: 'בנית', ready: 'מוכנה', great: 'מצוין' },
  neutral: { you: 'אתה', want: 'רוצה', built: 'בנית', ready: 'מוכן', great: 'מצוין' }
}

function buildSystemPrompt(profile) {
  const g = GENDER_FORMS[profile.gender] || GENDER_FORMS.neutral
  const name = profile.display_name

  return `אתה מנטור AI ידידותי ומסביר פנים שעוזר לילדים לבנות משחקי וידאו 2D פשוטים בדפדפן.
אתה מדבר עם ${name}, ילד/ה בגיל ${profile.age || '9-13'}.

# כללי שפה
- דבר תמיד בעברית.
- פנה אל ${name} בלשון ${profile.gender === 'female' ? 'נקבה' : 'זכר'}.
- שמור על שפה פשוטה, חמה ועידודית.
- אל תשתמש במונחים טכניים.

# כללי שיחה
- שאל בדיוק שאלה אחת בכל פעם - לא יותר.
- שאל רק על התנהגות המשחק: מה קורה כשקופצים, מה המטרה, מי הדמות, איך מנצחים/מפסידים.
- אל תשאל על צבעים, גדלים, פונטים, פיקסלים, או כל פרט טכני - אתה מחליט על אלה בעצמך.
- אם הילד מתקשה לתאר, הצע 2-3 דוגמאות קצרות שיעזרו לו להבין מה הוא רוצה.
- לאחר לא יותר מ-3 שאלות, גנרנה את המשחק עם ההנחות הטובות ביותר שלך.
- כשהמשחק מוכן, אמור: "GAME_READY" בשורה נפרדת לפני הקוד.

# כללי בטיחות
- אין אלימות, דם, תוכן למבוגרים.
- יריות/פגיעות מותרות רק בעצמים דוממים (אסטרואידים, כדורים, קוביות) - לא בבני אדם או חיות.
- אם הילד מבקש משהו לא בטוח, הפנה אותו בחיוך לחלופה יצירתית ובטוחה.

# יצירת קוד
כאשר אתה יוצר משחק:
1. כתוב קובץ HTML יחיד ושלם עם כל ה-CSS וה-JavaScript בתוכו.
2. פתח עם: <!DOCTYPE html><html dir="rtl" lang="he"><meta charset="UTF-8">
3. המשחק חייב לעבוד על מובייל (touch events) ועל מחשב (keyboard/mouse).
4. הוסף כפתורי מגע על המסך למובייל.
5. עצב בסגנון ססגוני, שמח ומתאים לגיל.
6. כתוב הודעות ב-UI בעברית.
7. הקוד חייב לעבוד מיידית, ללא ספריות חיצוניות.
8. כתוב: GAME_READY בשורה בפני עצמה, ואז את קוד ה-HTML בלבד - ללא הסברים אחרי הקוד.`
}

/**
 * Send a message in a game-building conversation.
 * @param {Object} profile - { display_name, gender, age }
 * @param {Array}  messages - Prior conversation [{ role, content }]
 * @param {string} userMessage - Latest user message
 * @returns {{ reply: string, gameHtml: string|null, questionCount: number }}
 */
export async function sendMessage({ profile, messages, userMessage }) {
  const systemPrompt = buildSystemPrompt(profile)

  const allMessages = [
    ...messages.map(m => ({ role: m.role, content: m.content })),
    { role: 'user', content: userMessage }
  ]

  const response = await client.messages.create({
    model: 'claude-opus-4-6',
    max_tokens: 4096,
    system: systemPrompt,
    messages: allMessages
  })

  const rawReply = response.content[0].text
  const gameHtml = extractGameHtml(rawReply)
  const reply = gameHtml
    ? rawReply.substring(0, rawReply.indexOf('GAME_READY')).trim() || `המשחק שלך מוכן, ${profile.display_name}!`
    : rawReply

  return { reply, gameHtml }
}

/**
 * Generate a name suggestion for a game given its HTML.
 */
export async function suggestGameName({ profile, gameHtml }) {
  const response = await client.messages.create({
    model: 'claude-haiku-4-5-20251001',
    max_tokens: 100,
    messages: [{
      role: 'user',
      content: `המשחק הבא נבנה על ידי ילד בשם ${profile.display_name}. הצע שם מגניב, קצר (2-4 מילים), בעברית בלבד. ענה עם השם בלבד, ללא הסברים.\n\n${gameHtml.substring(0, 500)}`
    }]
  })

  return response.content[0].text.trim()
}

/**
 * Attempt to self-correct broken game code.
 * @param {string} gameHtml - The broken HTML
 * @param {string} errorMessage - JS error from the sandbox
 */
export async function fixGameCode({ gameHtml, errorMessage }) {
  const response = await client.messages.create({
    model: 'claude-opus-4-6',
    max_tokens: 4096,
    messages: [{
      role: 'user',
      content: `קוד המשחק הבא גרם לשגיאה: "${errorMessage}"\n\nתקן את הקוד כך שיעבוד. ענה עם קוד HTML מתוקן בלבד, ללא הסברים.\n\n${gameHtml}`
    }]
  })

  return extractGameHtml(response.content[0].text) || response.content[0].text
}

function extractGameHtml(text) {
  const marker = 'GAME_READY'
  const idx = text.indexOf(marker)
  if (idx === -1) return null

  const afterMarker = text.slice(idx + marker.length).trim()
  const htmlStart = afterMarker.indexOf('<!DOCTYPE')
  if (htmlStart === -1) return null

  return afterMarker.slice(htmlStart).trim()
}
