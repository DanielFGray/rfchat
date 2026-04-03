import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import Placeholder from "@tiptap/extension-placeholder"
import Mention from "@tiptap/extension-mention"
import Link from "@tiptap/extension-link"
import MarkdownIt from "markdown-it"
import DOMPurify from "dompurify"
import { CATEGORY_ORDER, CATEGORY_LABELS, filterEmojiCatalog } from "./emoji_catalog"

const md = new MarkdownIt({
  html: false,
  linkify: true,
  breaks: true,
  typographer: false,
  highlight: (code, language) => {
    const languageLabel = language
      ? `<span class="inline-flex px-[0.9rem] pt-[0.55rem] text-[10px] font-extrabold uppercase tracking-[0.18em] text-zinc-400">${escapeHtml(language)}</span>`
      : ""
    return `<div class="message-code-block overflow-hidden rounded-[0.9rem] border border-white/6 bg-[rgb(17_18_20_/_0.92)]">${languageLabel}<pre class="m-0 overflow-x-auto px-[0.95rem] pt-[0.85rem] pb-4"><code class="text-[13px] text-zinc-200">${escapeHtml(code)}</code></pre></div>`
  },
})

const defaultLinkRenderer = md.renderer.rules.link_open || ((tokens, idx, options, env, self) => self.renderToken(tokens, idx, options))
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  tokens[idx].attrSet("target", "_blank")
  tokens[idx].attrSet("rel", "noopener noreferrer nofollow")
  tokens[idx].attrJoin("class", "text-blue-300 underline decoration-[rgba(147,197,253,0.4)] underline-offset-2")
  return defaultLinkRenderer(tokens, idx, options, env, self)
}

const ComposerEntity = Mention.extend({
  addAttributes() {
    return {
      ...this.parent?.(),
      entityType: {
        default: null,
        parseHTML: element => element.getAttribute("data-entity-type"),
        renderHTML: attributes => {
          if(!attributes.entityType) return {}
          return { "data-entity-type": attributes.entityType }
        },
      },
    }
  },

  renderText({ node }) {
    const prefix = node.attrs.mentionSuggestionChar === "/" ? "/" : "@"
    return `${prefix}${node.attrs.label ?? node.attrs.id}`
  },

  renderHTML({ node, HTMLAttributes }) {
    const isSlashCommand = node.attrs.mentionSuggestionChar === "/"

    return [
      "span",
      {
        ...HTMLAttributes,
        "data-entity-type": node.attrs.entityType || (isSlashCommand ? "slash_command" : "mention"),
        class: isSlashCommand
          ? "inline-flex items-center rounded-full bg-violet-500/18 px-2 py-0.5 text-[0.85em] font-bold text-violet-200"
          : "inline-flex items-center rounded-full bg-blue-500/18 px-2 py-0.5 text-[0.85em] font-bold text-blue-200",
      },
      `${isSlashCommand ? "/" : "@"}${node.attrs.label ?? node.attrs.id}`,
    ]
  },
})

const RichComposerHook = {
  mounted() {
    this.bodyInput = this.el.querySelector("#message-body-input")
    this.metadataInput = this.el.querySelector("#message-metadata-input")
    this.editorElement = this.el.querySelector("#rich-composer-editor")
    this.toolbar = this.el.querySelector("#rich-composer-toolbar")
    this.composerShell = this.el.querySelector("#rich-composer-shell")
    this.submitListener = () => this.syncInputs()
    this.editor = this.buildEditor()

    if(this.toolbar) {
      this.toolbar.addEventListener("click", this.handleToolbarClick)
    }

    this.el.addEventListener("submit", this.submitListener)

    this.handleEvent("composer:clear", () => {
      this.editor.commands.clearContent(true)
      this.syncInputs()
      this.syncComposerChrome()
      this.editor.commands.focus("end")
    })

    this.syncComposerChrome()
  },

  destroyed() {
    if(this.toolbar) {
      this.toolbar.removeEventListener("click", this.handleToolbarClick)
    }

    this.el.removeEventListener("submit", this.submitListener)

    this.editor?.destroy()
  },

  buildEditor() {
    this.handleToolbarClick = event => {
      const actionButton = event.target.closest("[data-editor-action]")
      if(!actionButton) return

      event.preventDefault()
      const action = actionButton.dataset.editorAction

      switch(action) {
        case "bold":
          this.editor.chain().focus().toggleBold().run()
          break
        case "italic":
          this.editor.chain().focus().toggleItalic().run()
          break
        case "inline-code":
          this.editor.chain().focus().toggleCode().run()
          break
        case "code-block":
          this.editor.chain().focus().toggleCodeBlock().run()
          break
        case "mention":
          this.editor.chain().focus().insertContent("@").run()
          break
        case "slash":
          this.editor.chain().focus().insertContent("/").run()
          break
        default:
          break
      }
    }

    return new Editor({
      element: this.editorElement,
      extensions: [
        StarterKit.configure({
          heading: false,
          blockquote: false,
          horizontalRule: false,
          strike: false,
          link: false,
        }),
        Placeholder.configure({
          placeholder: this.el.dataset.placeholder || "Message channel",
        }),
        Link.configure({
          autolink: true,
          openOnClick: false,
          protocols: ["http", "https"],
        }),
        ComposerEntity.configure({
          suggestions: [
            buildSuggestion({
              char: "@",
              items: () => parseDatasetJson(this.el.dataset.mentions).map(item => ({ ...item, entityType: item.type || "mention" })),
            }),
            buildSuggestion({
              char: "/",
              startOfLine: true,
              items: () => parseDatasetJson(this.el.dataset.commands).map(item => ({ ...item, entityType: "slash_command" })),
            }),
          ],
        }),
      ],
      editorProps: {
        attributes: {
          class: [
            "ProseMirror min-h-[44px] whitespace-pre-wrap break-words text-[15px] leading-6 text-zinc-100 outline-none",
            "[&>p]:m-0",
            "[&_p.is-editor-empty:first-child::before]:pointer-events-none",
            "[&_p.is-editor-empty:first-child::before]:float-left",
            "[&_p.is-editor-empty:first-child::before]:h-0",
            "[&_p.is-editor-empty:first-child::before]:text-zinc-500",
            "[&_p.is-editor-empty:first-child::before]:content-[attr(data-placeholder)]",
            "[&_code]:rounded-md [&_code]:bg-[rgba(17,18,20,0.75)] [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:text-[0.88em] [&_code]:text-zinc-100",
            "[&_pre]:mt-2 [&_pre]:overflow-x-auto [&_pre]:rounded-xl [&_pre]:bg-[rgb(17_18_20)] [&_pre]:px-4 [&_pre]:py-3.5",
            "[&_pre_code]:bg-transparent [&_pre_code]:p-0"
          ].join(" "),
          spellcheck: "true",
        },
      },
      autofocus: false,
      onCreate: () => {
        this.syncInputs()
        this.syncComposerChrome()
      },
      onUpdate: () => {
        this.syncInputs()
        this.syncComposerChrome()
      },
      onTransaction: ({ editor }) => {
        syncToolbarState(this.toolbar, editor)
      },
      onFocus: () => {
        this.syncComposerChrome()
      },
      onBlur: () => {
        requestAnimationFrame(() => this.syncComposerChrome())
      },
    })
  },

  syncInputs() {
    if(!this.bodyInput || !this.metadataInput || !this.editor) return

    const json = this.editor.getJSON()
    this.bodyInput.value = serializeMarkdown(json).trim()
    this.metadataInput.value = JSON.stringify({
      composer: "tiptap",
      entities: collectEntities(json),
      document: json,
    })

    this.bodyInput.dispatchEvent(new Event("input", { bubbles: true }))
    this.metadataInput.dispatchEvent(new Event("input", { bubbles: true }))
  },

  syncComposerChrome() {
    if(!this.composerShell || !this.editor) return

    const isExpanded = this.editor.isFocused || !this.editor.isEmpty
    this.composerShell.classList.toggle("is-focused", this.editor.isFocused)
    this.composerShell.classList.toggle("is-expanded", isExpanded)

    this.composerShell.querySelectorAll("[data-expanded]").forEach(node => {
      node.dataset.expanded = isExpanded ? "true" : "false"
    })
  },
}

const MessageListHook = {
  mounted() {
    this.autoscrollThreshold = 96
    this.shouldStickToBottom = true
    this.lastScrollHeight = this.el.scrollHeight
    this.onScroll = () => {
      this.shouldStickToBottom = this.isNearBottom()
    }

    this.el.addEventListener("scroll", this.onScroll)
    this.renderMarkdownBodies()
    this.handleEvent("notify:mention", payload => this.showMentionNotification(payload))
    this.handleEvent("notifications:request-permission", () => this.requestNotificationPermission())
    requestAnimationFrame(() => this.scrollToBottom())
  },

  updated() {
    const grew = this.el.scrollHeight > this.lastScrollHeight
    this.renderMarkdownBodies()

    if(grew && this.shouldStickToBottom) {
      requestAnimationFrame(() => this.scrollToBottom())
    }

    this.lastScrollHeight = this.el.scrollHeight
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
  },

  renderMarkdownBodies() {
    this.el.querySelectorAll("[data-markdown-source]").forEach(node => {
      const source = node.dataset.markdownSource || ""
      if(node.dataset.renderedSource === source) return

      const rendered = DOMPurify.sanitize(md.render(source))

      node.innerHTML = rendered
      node.dataset.renderedSource = source
      enhanceEmbeds(node)
    })
  },

  isNearBottom() {
    const remaining = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
    return remaining <= this.autoscrollThreshold
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },

  showMentionNotification(payload) {
    if(typeof window === "undefined" || typeof Notification === "undefined") return
    if(document.visibilityState === "visible") return
    if(Notification.permission !== "granted") return

    const bodyPreview = (payload.body || "").trim().slice(0, 140) || "You were mentioned in a message"
    const channelName = payload.channel_name ? `#${payload.channel_name}` : "another channel"

    const notification = new Notification(`${payload.author_name} mentioned you in ${channelName}`, {
      body: bodyPreview,
      tag: `mention-${payload.message_id}`,
    })

    notification.onclick = () => {
      window.focus()
      notification.close()
    }
  },

  requestNotificationPermission() {
    if(typeof window === "undefined" || typeof Notification === "undefined") return
    if(Notification.permission !== "default") return

    Notification.requestPermission().catch(() => {})
  },
}

const ReactionPickerHook = {
  mounted() {
    this.searchInput = this.el.querySelector("[data-reaction-picker-search]")
    this.defaultsContainer = this.el.querySelector("[data-reaction-picker-defaults]")
    this.categoriesContainer = this.el.querySelector("[data-reaction-picker-categories]")
    this.customContainer = this.el.querySelector("[data-reaction-picker-custom]")
    this.messageId = this.defaultsContainer?.dataset.messageId
    this.activeCategory = null
    this.query = ""

    this.customEmojiIds = new Set(parseDatasetJson(this.el.dataset.customEmojis).map(item => item.id))

    this.handleSearch = event => {
      this.query = event.target.value || ""
      this.renderCatalog()
    }

    this.handleCategoryClick = event => {
      const button = event.target.closest("[data-reaction-picker-category]")
      if(!button) return
      event.preventDefault()

      const nextCategory = button.dataset.reactionPickerCategory || null
      this.activeCategory = this.activeCategory === nextCategory ? null : nextCategory
      this.renderCatalog()
    }

    this.searchInput?.addEventListener("input", this.handleSearch)
    this.categoriesContainer?.addEventListener("click", this.handleCategoryClick)
    this.renderCatalog()
    this.searchInput?.focus()
  },

  updated() {
    this.customEmojiIds = new Set(parseDatasetJson(this.el.dataset.customEmojis).map(item => item.id))
    this.renderCatalog()
  },

  destroyed() {
    this.searchInput?.removeEventListener("input", this.handleSearch)
    this.categoriesContainer?.removeEventListener("click", this.handleCategoryClick)
  },

  renderCatalog() {
    if(!this.defaultsContainer || !this.categoriesContainer || !this.messageId) return

    const items = filterEmojiCatalog(this.query, this.activeCategory)
    this.renderCategories(items)
    this.renderDefaults(items)
    this.filterCustomEmojis()
  },

  renderCategories(items) {
    const availableCategories = new Set(items.map(item => item.category))

    this.categoriesContainer.innerHTML = ""

    CATEGORY_ORDER.forEach(categoryId => {
      if(this.query && !availableCategories.has(categoryId)) return

      const button = document.createElement("button")
      button.type = "button"
      button.dataset.reactionPickerCategory = categoryId
      button.className = [
        "rounded-full border px-2.5 py-1.5 text-[10px] font-semibold transition md:px-2 md:py-1",
        this.activeCategory === categoryId
          ? "border-violet-400/60 bg-violet-500/20 text-violet-100"
          : "border-white/10 bg-black/10 text-zinc-400 hover:border-white/20 hover:text-zinc-200",
      ].join(" ")
      button.textContent = CATEGORY_LABELS[categoryId] || categoryId
      this.categoriesContainer.appendChild(button)
    })
  },

  renderDefaults(items) {
    this.defaultsContainer.innerHTML = ""

    if(items.length === 0) {
      const empty = document.createElement("p")
      empty.className = "col-span-7 rounded-xl border border-dashed border-white/8 bg-black/10 px-3 py-4 text-center text-xs text-zinc-500 md:col-span-6"
      empty.textContent = "No default emojis match that search."
      this.defaultsContainer.appendChild(empty)
      return
    }

    items.forEach(entry => {
      const button = document.createElement("button")
      button.type = "button"
      button.setAttribute("phx-click", "toggle_reaction")
      button.setAttribute("phx-value-id", this.messageId)
      button.setAttribute("phx-value-emoji", entry.emoji)
      button.id = `reaction-picker-default-${this.messageId}-${entry.unified}`
      button.className = "flex h-11 items-center justify-center rounded-xl border border-white/8 bg-black/10 text-xl transition hover:border-white/20 hover:bg-white/6 md:h-9 md:text-lg"
      button.title = entry.name
      button.setAttribute("aria-label", entry.name)
      button.textContent = entry.emoji
      this.defaultsContainer.appendChild(button)
    })
  },

  filterCustomEmojis() {
    if(!this.customContainer) return

    const normalizedQuery = this.query.trim().toLowerCase()

    this.customContainer.querySelectorAll("[data-custom-emoji-id]").forEach(node => {
      const name = (node.dataset.customEmojiName || "").toLowerCase()
      const shortcode = (node.dataset.customEmojiShortcode || "").toLowerCase()
      const visible = normalizedQuery === "" || name.includes(normalizedQuery) || shortcode.includes(normalizedQuery)
      node.classList.toggle("hidden", !visible)
    })
  },
}

function buildSuggestion({ char, items, startOfLine = false }) {
  return {
    char,
    startOfLine,
    items: ({ query }) => filterItems(items(), query),
    render: () => {
      let popup
      let selectedIndex = 0
      let activeItems = []
      let command = null

      const renderPopup = props => {
        if(!popup) return

        activeItems = props.items
        popup.innerHTML = ""

        if(activeItems.length === 0) {
          popup.innerHTML = '<div class="flex w-full flex-col gap-0.5 px-[0.85rem] py-[0.7rem] text-left text-[0.72rem] text-zinc-400">No matches</div>'
          return
        }

        activeItems.forEach((item, index) => {
          const option = document.createElement("button")
          option.type = "button"
          option.className = [
            "flex w-full flex-col gap-0.5 px-[0.85rem] py-[0.7rem] text-left transition",
            index === selectedIndex ? "bg-white/6" : "bg-transparent hover:bg-white/6",
          ].join(" ")
          option.innerHTML = `
            <span class="text-[0.86rem] font-bold text-zinc-100">${char}${escapeHtml(item.label)}</span>
            <span class="text-[0.72rem] text-zinc-400">${escapeHtml(item.description || "")}</span>
          `
          option.addEventListener("mousedown", event => {
            event.preventDefault()
            props.command({ id: item.id, label: item.label })
          })
          popup.appendChild(option)
        })
      }

      const reposition = props => {
        if(!popup || !props.clientRect) return
        const rect = props.clientRect()
        if(!rect) return

        popup.style.left = `${rect.left + window.scrollX}px`
        popup.style.top = `${rect.bottom + window.scrollY + 8}px`
      }

      return {
        onStart: props => {
          selectedIndex = 0
          command = props.command
          popup = document.createElement("div")
          popup.className = "absolute z-80 min-w-60 max-w-80 overflow-hidden rounded-[0.9rem] border border-white/8 bg-[rgb(17_18_20_/_0.97)] shadow-[0_18px_40px_rgba(0,0,0,0.35)]"
          document.body.appendChild(popup)
          renderPopup(props)
          reposition(props)
        },
        onUpdate: props => {
          selectedIndex = 0
          command = props.command
          renderPopup(props)
          reposition(props)
        },
        onKeyDown: props => {
          if(props.event.key === "Escape") {
            popup?.remove()
            return true
          }

          if(props.event.key === "ArrowDown") {
            selectedIndex = (selectedIndex + 1) % Math.max(activeItems.length, 1)
            renderPopup(props)
            return true
          }

          if(props.event.key === "ArrowUp") {
            selectedIndex = (selectedIndex - 1 + Math.max(activeItems.length, 1)) % Math.max(activeItems.length, 1)
            renderPopup(props)
            return true
          }

          if(props.event.key === "Enter" && activeItems[selectedIndex]) {
            command({ id: activeItems[selectedIndex].id, label: activeItems[selectedIndex].label })
            return true
          }

          return false
        },
        onExit: () => {
          popup?.remove()
          popup = null
        },
      }
    },
  }
}

function filterItems(items, query) {
  const normalizedQuery = query.trim().toLowerCase()

  return items
    .filter(item => {
      if(normalizedQuery === "") return true
      return item.label.toLowerCase().includes(normalizedQuery)
    })
    .slice(0, 6)
}

function parseDatasetJson(value) {
  try {
    return JSON.parse(value || "[]")
  } catch (_error) {
    return []
  }
}

function serializeMarkdown(node, depth = 0) {
  if(!node) return ""

  if(node.type === "doc") {
    return normalizeSerializedMarkdown((node.content || []).map(child => serializeMarkdown(child, depth)).join(""))
  }

  switch(node.type) {
    case "paragraph": {
      const content = (node.content || []).map(child => serializeMarkdown(child, depth)).join("")
      return `${content}\n\n`
    }

    case "text":
      return applyMarks(node.text || "", node.marks || [])

    case "hardBreak":
      return "\n"

    case "mention": {
      const prefix = node.attrs?.mentionSuggestionChar === "/" ? "/" : "@"
      return `${prefix}${node.attrs?.label || node.attrs?.id || ""}`
    }

    case "codeBlock": {
      const code = collectPlainText(node)
      return `\n\n\`\`\`${node.attrs?.language || ""}\n${code}\n\`\`\`\n\n`
    }

    case "bulletList":
      return (node.content || []).map(child => serializeListItem(child, "-", depth)).join("") + "\n"

    case "orderedList":
      return (node.content || []).map((child, index) => serializeListItem(child, `${index + 1}.`, depth)).join("") + "\n"

    default:
      return (node.content || []).map(child => serializeMarkdown(child, depth)).join("")
  }
}

function serializeListItem(node, bullet, depth) {
  const itemContent = (node.content || []).map(child => serializeMarkdown(child, depth + 1)).join("").trim()
  const indent = "  ".repeat(depth)
  const normalized = itemContent.replace(/\n{2,}/g, "\n").split("\n").join(`\n${indent}  `)
  return `${indent}${bullet} ${normalized}\n`
}

function applyMarks(text, marks) {
  return marks.reduce((content, mark) => {
    switch(mark.type) {
      case "bold":
        return `**${content}**`
      case "italic":
        return `*${content}*`
      case "code":
        return `\`${content}\``
      case "link":
        return `[${content}](${mark.attrs?.href || "#"})`
      default:
        return content
    }
  }, text)
}

function collectPlainText(node) {
  if(!node) return ""
  if(node.type === "text") return node.text || ""
  return (node.content || []).map(collectPlainText).join("")
}

function collectEntities(node, entities = []) {
  if(!node) return entities

  if(node.type === "mention") {
    entities.push({
      type: node.attrs?.entityType || (node.attrs?.mentionSuggestionChar === "/" ? "slash_command" : "mention"),
      id: node.attrs?.id,
      label: node.attrs?.label,
    })
  }

  ;(node.content || []).forEach(child => collectEntities(child, entities))
  return entities
}

function normalizeSerializedMarkdown(markdown) {
  return markdown
    .replace(/\n{3,}/g, "\n\n")
    .replace(/(?:\n\s*)+$/g, "")
}

function syncToolbarState(toolbar, editor) {
  if(!toolbar) return

  toolbar.querySelectorAll("[data-editor-action]").forEach(button => {
    const action = button.dataset.editorAction
    const active =
      (action === "bold" && editor.isActive("bold")) ||
      (action === "italic" && editor.isActive("italic")) ||
      (action === "inline-code" && editor.isActive("code")) ||
      (action === "code-block" && editor.isActive("codeBlock"))

    button.classList.toggle("is-active", !!active)
    button.dataset.active = active ? "true" : "false"
  })
}

function escapeHtml(value) {
  return `${value}`
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

function enhanceEmbeds(container) {
  container.querySelectorAll("p").forEach(paragraph => {
    if(paragraph.childElementCount !== 1) return
    const link = paragraph.querySelector("a")
    if(!link) return
    const text = paragraph.textContent.trim()
    if(text !== link.href && text !== link.textContent.trim()) return

    const embed = document.createElement("a")
    embed.href = link.href
    embed.target = "_blank"
    embed.rel = "noopener noreferrer nofollow"
    embed.className = "flex flex-col gap-1 rounded-[0.85rem] border border-blue-400/20 bg-slate-800/55 px-[0.9rem] py-3 text-left no-underline"

    let url
    try {
      url = new URL(link.href)
    } catch (_error) {
      return
    }
    embed.innerHTML = `
      <span class="text-[11px] font-extrabold uppercase tracking-[0.18em] text-slate-400">${escapeHtml(url.hostname)}</span>
      <span class="break-all text-[13px] text-blue-200">${escapeHtml(link.href)}</span>
    `

    paragraph.replaceWith(embed)
  })
}

export { MessageListHook, ReactionPickerHook, RichComposerHook }
