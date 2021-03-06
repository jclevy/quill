Quill    = require('../quill')
Document = require('../core/document')
_        = Quill.require('lodash')
dom      = Quill.require('dom')
Delta    = Quill.require('delta')

class PasteManager
  @DEFAULTS:
    onConvert: null

  constructor: (@quill, options) ->
    @container = @quill.addContainer('ql-paste-manager')
    @container.setAttribute('contenteditable', true)
    @container.setAttribute('tabindex', '-1')
    dom(@quill.root).on('paste', _.bind(this._paste, this))
    dom(@quill.root).on('copy', _.bind(this._copy, this))
    @options = _.defaults(options, PasteManager.DEFAULTS)
    @options.onConvert ?= this._onConvert;

  _onConvert: (container) =>
    doc = new Document(container, @quill.options, @quill)
    delta = doc.toDelta()
    lengthAdded = delta.length()
    if lengthAdded == 0
      return delta
    # Need to remove trailing newline so paste is inline, losing format is expected and observed in Word
    return delta.compose(new Delta().retain(lengthAdded - 1).delete(1))

  _copy: ->
    range = this.quill.getSelection()
    return unless range?

    yes

  _paste: ->
    oldDocLength = @quill.getLength()
    range = @quill.getSelection()
    return unless range?
    bounds = @quill.editor.getBounds(range.start)
    dom(@container).styles(top:Math.round(@quill.container.scrollTop + bounds.top) + 'px')
    @container.focus()
    _.defer( =>
      delta = @options.onConvert(@container)
      lengthAdded = delta.length()
      if lengthAdded > 0
        delta.ops.unshift({ retain: range.start }) if range.start > 0
        delta.delete(range.end - range.start)
        @quill.updateContents(delta, 'user')
      @quill.setSelection(range.start + lengthAdded, range.start + lengthAdded)
      @container.innerHTML = ""
    )


Quill.registerModule('paste-manager', PasteManager)
module.exports = PasteManager
