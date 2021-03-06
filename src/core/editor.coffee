_         = require('lodash')
Delta     = require('rich-text/lib/delta')
dom       = require('../lib/dom')
Document  = require('./document')
Line      = require('./line')
Selection = require('./selection')
Uuid       = require('../lib/uuid')


class Editor
  @sources:
    API    : 'api'
    SILENT : 'silent'
    USER   : 'user'

  constructor: (@root, @quill, @options = {}) ->
    @root.setAttribute('id', @options.id)
    @doc = new Document(@root, @options, @quill)
    @delta = @doc.toDelta()
    @length = @delta.length()
    @selection = new Selection(@doc, @quill)
    @timer = setInterval(_.bind(this.checkUpdate, this), @options.pollInterval)
    @savedRange = null;
    @quill.on("selection-change", (range) =>
      @savedRange = range
    )
    this.enable() unless @options.readOnly

  destroy: ->
    clearInterval(@timer)

  disable: ->
    this.enable(false)

  enable: (enabled = true) ->
    @root.setAttribute('contenteditable', enabled)

  applyDelta: (delta, source) ->
    delete @doc.lines.forwardUuid
    localDelta = this._update()
    if localDelta
      delta = localDelta.transform(delta, true)
      localDelta = delta.transform(localDelta, false)
    oneDeletedInline = false
    if delta.ops.length is 2 and delta.ops[0].retain? and delta.ops[1].delete is 1
      togo = delta.ops[0].retain
      for op in @delta.ops
        op_togo = op.retain ? op.insert.length
        if op_togo > togo then if op.insert?
          if op.insert.length > togo + 1
            op.insert = op.insert.substr(0, togo) + op.insert.substr(togo + 1) ; @length += 1
            oneDeletedInline = true
          break
        else togo += -op_togo

      if oneDeletedInline
        lines = @doc.lines.toArray()
        retained = 0
        for line in lines
          if retained + line.length > delta.ops[0].retain
            @selection.shiftAfter(0, -1, -> line.deleteText(delta.ops[0].retain - retained, 1))
            @quill?.emit(@quill.constructor.events.LINE_CHANGE, line)
            break
          else retained += line.length

    unless oneDeletedInline
      if delta.ops.length > 0
        delta = this._trackDelta( =>
          index = 0
          _.each(delta.ops, (op) =>
            if _.isString(op.insert)
              this._insertAt(index, op.insert, op.attributes)
              index += op.insert.length;
            else if _.isNumber(op.insert)
              this._insertEmbed(index, op.attributes)
              index += 1;
            else if _.isNumber(op.delete)
              this._deleteAt(index, op.delete)
            else if _.isNumber(op.retain)
              _.each(op.attributes, (value, name) =>
                this._formatAt(index, op.retain, name, value)
              )
              index += op.retain
          )
          @selection.shiftAfter(0, 0, _.bind(@doc.optimizeLines, @doc))
        )
        @delta = @doc.toDelta()
        @length = @delta.length()
        
    @innerHTML = @root.innerHTML
    @quill.emit(@quill.constructor.events.TEXT_CHANGE, delta, source) if delta and source != Editor.sources.SILENT
    if localDelta and localDelta.ops.length > 0 and source != Editor.sources.SILENT
      @quill.emit(@quill.constructor.events.TEXT_CHANGE, localDelta, Editor.sources.USER)

  checkUpdate: (source = 'user') ->
    return clearInterval(@timer) unless @root.parentNode?
    delta = this._update()
    if delta
      if delta.ops.length is 2 and delta.ops[0].retain? and delta.ops[1].insert? and delta.ops[1].insert.length is 1 and delta.ops[1].insert isnt'\n'
        togo = delta.ops[0].retain
        for op in @delta.ops
          op_togo = op.retain ? op.insert.length
          if op_togo > togo then if op.insert? then op.insert = op.insert.substr(0, togo) + delta.ops[1].insert + op.insert.substr(togo) ; @length += 1 ; break
          else togo += -op_togo
      else
        @delta = @delta.compose(delta)
        @length = @delta.length()
      @quill.emit(@quill.constructor.events.TEXT_CHANGE, delta, source)
    source = Editor.sources.SILENT if delta
    @selection.update(source)

  focus: ->
    if @selection.range?
      @selection.setRange(@selection.range)
    else
      @root.focus()

  getBounds: (index) ->
    this.checkUpdate()
    [leaf, offset] = @doc.findLeafAt(index, true)
    return null unless leaf?
    containerBounds = @root.parentNode.getBoundingClientRect()
    side = 'left'
    if leaf.length == 0   # BR case
      bounds = leaf.node.parentNode.getBoundingClientRect()
    else if dom.VOID_TAGS[leaf.node.tagName]
      bounds = leaf.node.getBoundingClientRect()
      side = 'right' if offset == 1
    else
      range = document.createRange()
      if offset < leaf.length
        range.setStart(leaf.node, offset)
        range.setEnd(leaf.node, offset + 1)
      else
        range.setStart(leaf.node, offset - 1)
        range.setEnd(leaf.node, offset)
        side = 'right'
      bounds = range.getBoundingClientRect()
    return {
      height: bounds.height
      left: bounds[side] - containerBounds.left
      top: bounds.top - containerBounds.top
    }

  _deleteAt: (index, length) ->
    return if length <= 0
    @selection.shiftAfter(index, -1 * length, =>
      [firstLine, offset] = @doc.findLineAt(index)
      curLine = firstLine
      mergeFirstLine = firstLine.length - offset <= length and offset > 0
      while curLine? and length > 0
        nextLine = curLine.next
        deleteLength = Math.min(curLine.length - offset, length)
        if offset == 0 and length >= curLine.length
          @doc.removeLine(curLine)
        else
          curLine.deleteText(offset, deleteLength)
          @quill?.emit(@quill.constructor.events.LINE_CHANGE, curLine)
        length -= deleteLength
        curLine = nextLine
        offset = 0
      @doc.mergeLines(firstLine, firstLine.next) if mergeFirstLine and firstLine.next
    )

  _formatAt: (index, length, name, value) ->
    @selection.shiftAfter(index, 0, =>
      [line, offset] = @doc.findLineAt(index)
      while line? and length > 0
        formatLength = Math.min(length, line.length - offset - 1)
        line.formatText(offset, formatLength, name, value)
        length -= formatLength
        line.format(name, value) if length > 0
        length -= 1
        offset = 0
        @quill?.emit(@quill.constructor.events.LINE_CHANGE, line)
        line = line.next
    )

  _insertEmbed: (index, attributes) ->
    @selection.shiftAfter(index, 1, =>
      [line, offset] = @doc.findLineAt(index)
      line.insertEmbed(offset, attributes)
    )

  _insertAt: (index, text, formatting = {}) ->
    uuid = formatting.uuid
    @selection.shiftAfter(index, text.length, =>
      text = text.replace(/\r\n?/g, '\n')
      lineTexts = text.split('\n')
      [line, offset] = @doc.findLineAt(index)
      _.each(lineTexts, (lineText, i) =>
        if !line? or line.length <= offset    # End of document
          if i < lineTexts.length - 1 or lineText.length > 0
            line = @doc.appendLine(document.createElement(dom.DEFAULT_BLOCK_TAG), uuid)
            offset = 0
            line.insertText(offset, lineText, formatting)
            line.format(formatting)
            nextLine = null
            @quill?.emit(@quill.constructor.events.LINE_CHANGE, line)
        else
          if formatting.uuid? and @doc.lines.uuids[formatting.uuid]?
            if formatting.uuid isnt line.uuid or lineTexts.length > 1
              formatting.uuid = uuid = Uuid()
          if i < lineTexts.length - 1       # Are there more lines to insert?
            delete formatting.uuid if formatting.uuid?
            line.insertText(offset, lineText, formatting)
            formatting.uuid = uuid if uuid?
            nextLine = @doc.splitLine(line, offset + lineText.length, uuid, offset < (line.length - lineText.length - 1) / 2)
            _.each(_.defaults({}, formatting, line.formats), (value, format) ->
              line.format(format, formatting[format])
            )
            @quill?.emit(@quill.constructor.events.LINE_CHANGE, line)
            offset = 0
          else
            doc_forwardUuid = @doc.lines.forwardUuid
            line.insertText(offset, lineText, formatting)
            if formatting?.uuid?
              if formatting.uuid is line.uuid
                line_inserted = not @doc.lines.uuids[line.uuid]?
                new_forwardUuid = @doc.lines.forwardUuid? and @doc.lines.forwardUuid isnt doc_forwardUuid
                unused_forwardUuid = not new_forwardUuid and @doc.lines.forwardUuid? and @doc.lines.forwardUuid isnt line.uuid
                @doc.lines.uuids[formatting.uuid] = line
                @quill?.emit(@quill.constructor.events.LINE_LINK, line.prev) if line.prev?
                @quill?.emit(@quill.constructor.events.LINE_LINK, line.next) if line.next?
                @quill?.emit(@quill.constructor.events[if line_inserted then "LINE_INSERT" else "LINE_CHANGE"], line)
                if line_inserted
                  if unused_forwardUuid
                    @quill?.emit(@quill.constructor.events.LINE_REMOVE, uuid:@doc.lines.forwardUuid)
                    delete @doc.lines.uuids[@doc.lines.forwardUuid]
                    delete @doc.lines.forwardUuid
                  else if new_forwardUuid
                    @quill?.emit(@quill.constructor.events.LINE_REMOVE, uuid:@doc.lines.forwardUuid)
                    delete @doc.lines.uuids[@doc.lines.forwardUuid]
            else
              @quill?.emit(@quill.constructor.events.LINE_CHANGE, line)

        line = nextLine
      )
    )

  _trackDeltaOne: ->
    delta = null
    oldIndex = @savedRange?.start
    @savedRange = @selection.getRange()
    newIndex = @savedRange?.start
    if newIndex - oldIndex is 1
      lines = @doc.lines.toArray()
      lineNode = @doc.root.firstChild
      lineNode = lineNode.firstChild if lineNode? and dom.LIST_TAGS[lineNode.tagName]?
      retained = 0
      for line in lines
        if line.outerHTML != lineNode.outerHTML
          line.node = @doc.normalizer.normalizeLine(line.node)
          line.rebuild()
          @quill?.emit(@quill.constructor.events.LINE_CHANGE, line)
          delta = new Delta().retain(newIndex-1)
          _.each(line.delta.ops, (op) ->
            delta.push(op)
          )
          delta.ops[1].insert = delta.ops[1].insert.substr(newIndex-retained-1, 1)
          break
        else
          retained += line.length
          lineNode = dom(lineNode).nextLineNode(@doc.root)
    delta

  _trackDelta: (fn) ->
    delta = this._trackDeltaOne()
    return delta if delta?

    oldIndex = @savedRange?.start
    fn()
    @savedRange = @selection.getRange()
    newIndex = @savedRange?.start
    try
      if oldIndex? and newIndex? and oldIndex <= @delta.length() and newIndex <= (newDelta = @doc.toDelta()).length()
        oldRightDelta = @delta.slice(oldIndex)
        newRightDelta = newDelta.slice(newIndex)
        if _.isEqual(oldRightDelta.ops, newRightDelta.ops)
          oldLeftDelta = @delta.slice(0, oldIndex)
          newLeftDelta = newDelta.slice(0, newIndex)
          return oldLeftDelta.diff(newLeftDelta)
    catch ignored
    return @delta.diff(newDelta ? @doc.toDelta())

  _update: ->
    return false if @innerHTML == @root.innerHTML
    delta = this._trackDelta( =>
      @selection.preserve(_.bind(@doc.rebuild, @doc))
      @selection.shiftAfter(0, 0, _.bind(@doc.optimizeLines, @doc))
    )
    @innerHTML = @root.innerHTML
    return if delta.ops.length > 0 then delta else false


module.exports = Editor
