import emojiMartData from "@emoji-mart/data"

const CATEGORY_ORDER = ["people", "nature", "foods", "activity", "places", "objects", "symbols", "flags"]

const CATEGORY_LABELS = {
  people: "Smileys & People",
  nature: "Animals & Nature",
  foods: "Food & Drink",
  activity: "Activities",
  places: "Travel & Places",
  objects: "Objects",
  symbols: "Symbols",
  flags: "Flags",
}

const CATEGORY_ICONS = {
  people: "🙂",
  nature: "🌿",
  foods: "🍔",
  activity: "⚽",
  places: "🌍",
  objects: "💡",
  symbols: "🔣",
  flags: "🏳️",
}

const EMOJI_VERSION = emojiMartData.meta?.emojiVersion || 0

const emojiById = emojiMartData.emojis || {}

const emojiCatalog = CATEGORY_ORDER.flatMap(categoryId => {
  const category = emojiMartData.categories.find(item => item.id === categoryId)
  if(!category) return []

  return category.emojis.flatMap(emojiId => buildEmojiEntries(emojiById[emojiId], categoryId))
})

function buildEmojiEntries(emoji, categoryId) {
  if(!emoji || !emoji.skins?.length) return []

  return emoji.skins
    .filter(skin => skin.native)
    .map((skin, index) => ({
      id: `${emoji.id}:${skin.unified}`,
      emoji: skin.native,
      native: skin.native,
      name: variantName(emoji.name, index),
      shortcodes: [emoji.id, ...(emoji.keywords || [])],
      keywords: emoji.keywords || [],
      category: categoryId,
      categoryLabel: CATEGORY_LABELS[categoryId] || categoryId,
      version: emoji.version || EMOJI_VERSION,
      skinTone: index,
      unified: skin.unified,
    }))
}

function variantName(baseName, skinIndex) {
  if(skinIndex === 0) return baseName

  return `${baseName}: ${skinToneLabel(skinIndex)}`
}

function skinToneLabel(index) {
  switch(index) {
    case 1:
      return "light skin tone"
    case 2:
      return "medium-light skin tone"
    case 3:
      return "medium skin tone"
    case 4:
      return "medium-dark skin tone"
    case 5:
      return "dark skin tone"
    default:
      return "variant"
  }
}

function filterEmojiCatalog(query, activeCategory = null, limit = 240) {
  const normalizedQuery = query.trim().toLowerCase()

  const filtered = emojiCatalog.filter(entry => {
    if(activeCategory && entry.category !== activeCategory) return false
    if(normalizedQuery === "") return true

    const haystack = [entry.name, ...entry.shortcodes, ...entry.keywords, entry.native]
      .join(" ")
      .toLowerCase()

    return haystack.includes(normalizedQuery)
  })

  return filtered.slice(0, limit)
}

export { CATEGORY_ICONS, CATEGORY_ORDER, CATEGORY_LABELS, emojiCatalog, filterEmojiCatalog }
