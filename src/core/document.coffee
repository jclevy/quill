_          = require('lodash')
Delta      = require('rich-text/lib/delta')
dom        = require('../lib/dom')
Format     = require('./format')
Line       = require('./line')
LinkedList = require('../lib/linked-list')
Normalizer = require('./normalizer')
Uuid       = require('../lib/uuid')


class Document
  constructor: (@root, options = {}, @quill) ->
    @normalizer = new Normalizer()
    @formats = {}
    _.each(options.formats, _.bind(this.addFormat, this))
    this.setHTML(@root.innerHTML)

  addFormat: (name, config) ->
    config = Format.FORMATS[name] unless _.isObject(config)
    console.warn('Overwriting format', name, @formats[name]) if @formats[name]?
    @formats[name] = new Format(config)
    @normalizer.addFormat(config)

  appendLine: (lineNode, uuid) ->
    unless uuid? then uuid = lineNode.getAttribute Line.UUID_KEY
    return this.insertLineBefore(lineNode, null, uuid)

  findLeafAt: (index, inclusive) ->
    [line, offset] = this.findLineAt(index)
    return if line? then line.findLeafAt(offset, inclusive) else [undefined, offset]

  findLine: (node) ->
    while node? and !dom.BLOCK_TAGS[node.tagName]?
      node = node.parentNode
    line = if node? then dom(node).data(Line.DATA_KEY) else undefined
    return if line?.node == node then line else undefined

  findLineAt: (index) ->
    return [undefined, index] unless @lines.length > 0
    curLine = @lines.first
    while curLine?
      return [curLine, index] if index < curLine.length or (curLine is @lines.last and index is curLine.length)
      index -= curLine.length
      curLine = curLine.next
    return [undefined, index]

  getHTML: ->
    # Preserve spaces between tags
    return @root.innerHTML.replace(/\>\s+\</g, '>&nbsp;<')

  insertLineBefore: (newLineNode, refLine, uuid, forwardUuid, formats) ->
    uuid = Uuid() if forwardUuid is false and uuid? and @lines.uuids[uuid]?
    line = new Line(this, newLineNode, uuid, @quill.modules["paste-manager"]?.container isnt @root)
    @lines.uuids[line.uuid] = line if line.uuid?
    if refLine?
      @root.insertBefore(newLineNode, refLine.node) unless dom(newLineNode.parentNode).isElement()  # Would prefer newLineNode.parentNode? but IE will have non-null object
      @lines.insertAfter(refLine.prev, line)
    else
      @root.appendChild(newLineNode) unless dom(newLineNode.parentNode).isElement()
      @lines.append(line)
    if formats?
      line.formats = formats
      line.resetContent()
    unless @quill.modules["paste-manager"]?.container is @root
      if forwardUuid
        @quill?.emit(@quill.constructor.events.LINE_CHANGE, line)
      else
        @quill?.emit(@quill.constructor.events.LINE_INSERT, line)
      @quill?.emit(@quill.constructor.events.LINE_LINK, line.prev) if line.prev?
      @quill?.emit(@quill.constructor.events.LINE_LINK, line.next) if line.next?
    return line

  mergeLines: (line, lineToMerge) ->
    if lineToMerge.length > line.length
      swap = line
      line = lineToMerge
      lineToMerge = swap

    if lineToMerge.length > 1
      dom(line.leaves.last.node).remove() if line.length == 1
      if swap? then firstChild = line.node.firstChild
      _.each(dom(lineToMerge.node).childNodes(), (child) ->
        if child.tagName != dom.DEFAULT_BREAK_TAG
          unless swap?
            line.node.appendChild(child)
          else
            line.node.insertBefore(child, firstChild)
      )
    this.removeLine(lineToMerge)
    line.rebuild()
    @quill?.emit(@quill.constructor.events.LINE_MERGE, line, lineToMerge.uuid)

  optimizeLines: ->
    # TODO optimize algorithm (track which lines get dirty and only Normalize.optimizeLine those)
    _.each(@lines.toArray(), (line, i) ->
      line.optimize()
      return true    # line.optimize() might return false, prevent early break
    )

  rebuild: ->
    lines = @lines.toArray()
    lineNode = @root.firstChild
    lineNode = lineNode.firstChild if lineNode? and dom.LIST_TAGS[lineNode.tagName]?
    lineChanged = null
    cutOccured = false
    _.each(lines, (line, index) =>
      while line.node != lineNode
        if line.node.parentNode == @root or line.node.parentNode?.parentNode == @root
          # New line inserted
          lineNode = @normalizer.normalizeLine(lineNode)
          newLine = this.insertLineBefore(lineNode, line)
          lineNode = dom(lineNode).nextLineNode(@root)
        else
          # Existing line removed
          if cutOccured
            removed =
              uuid: lineChanged.uuid
              next: lineChanged

            lineChanged.uuid = line.uuid
            lineChanged.next = line.next
            lineChanged.next.prev = lineChanged if lineChanged.next?
            lineChanged.rebuild(true)
            @lines.uuids[lineChanged.uuid] = lineChanged
            line.uuid = removed.uuid
            line.prev = lineChanged.prev
            line.next = removed.next
            isRemovingLast = @lines.last is line
            this.removeLine(line)
            if isRemovingLast and not lineChanged.next?
              @lines.last = lineChanged
            lineChanged = undefined
            return
          this.removeLine(line)
          return

      if line.outerHTML != lineNode.outerHTML
        cutOccured = true if line.node.outerHTML != line.outerHTML
        # Existing line changed
        line.node = @normalizer.normalizeLine(line.node)
        line.rebuild()
        lineChanged = line
      lineNode = dom(lineNode).nextLineNode(@root)

    )
    if lineChanged?
        @quill?.emit(@quill.constructor.events.LINE_CHANGE, lineChanged)

    # New lines appended
    while lineNode?
      lineNode = @normalizer.normalizeLine(lineNode)
      this.appendLine(lineNode)
      lineNode = dom(lineNode).nextLineNode(@root)

  removeLine: (line) ->
    if line.node.parentNode?
      if dom.LIST_TAGS[line.node.parentNode.tagName] and line.node.parentNode.childNodes.length == 1
        dom(line.node.parentNode).remove()
      else
        dom(line.node).remove()
    links = prev:line.prev, next:line.next
    lines = @lines.remove(line)
    delete @lines.uuids[line.uuid] if line.uuid?
    @quill?.emit(@quill.constructor.events.LINE_LINK, links.prev) if links.prev?
    @quill?.emit(@quill.constructor.events.LINE_LINK, links.next) if links.next?
    @quill?.emit(@quill.constructor.events.LINE_REMOVE, line)
    return lines


  setHTML: (html) ->
    html = Normalizer.stripComments(html)
    html = Normalizer.stripWhitespace(html)
    @root.innerHTML = html
    @lines = new LinkedList()
    @lines.uuids = {}
    this.rebuild()

  splitLine: (line, offset, lineNewUuid, forwardUuid = false) ->
    forwardUuid = true if lineNewUuid?
    offset = Math.min(offset, line.length - 1)
    [lineNode1, lineNode2] = dom(line.node).split(offset, true)
    line.node = lineNode1
    if @lines.forwardUuid? and @lines.forwardUuid isnt line.uuid
      newLineUuid = @lines.forwardUuid
      lineNewUuid = line.uuid
      lineWasInserted = not @lines.uuids[newLineUuid]?
      delete @lines.uuids[newLineUuid] unless lineWasInserted
      delete @lines.forwardUuid
    else if forwardUuid
      newLineUuid = line.uuid
    if line.rebuild(false, forwardUuid, lineNewUuid)
      if forwardUuid
        line.uuid = Uuid() if @lines.uuids[line.uuid]?
        @lines.uuids[line.uuid] = line if line.uuid?
      else
        @quill?.emit(@quill.constructor.events.LINE_CHANGE, line)
    if lineWasInserted
      @quill?.emit(@quill.constructor.events.LINE_LINK, line.prev) if line.prev?
    else if forwardUuid
      @quill?.emit(@quill.constructor.events.LINE_LINK, line.prev) if line.prev?
      @quill?.emit(@quill.constructor.events.LINE_INSERT, line)
    newLine = this.insertLineBefore(lineNode2, line.next, newLineUuid, forwardUuid or lineWasInserted, _.clone(line.formats))
    if lineWasInserted
      @quill?.emit(@quill.constructor.events.LINE_INSERT, newLine)
    else if forwardUuid
      @quill?.emit(@quill.constructor.events.LINE_LINK, newLine)
    return newLine

  toDelta: ->
    lines = @lines.toArray()
    delta = new Delta()
    _.each(lines, (line) ->
      _.each(line.delta.ops, (op) ->
        delta.push(op)
      )
    )
    return delta


module.exports = Document
