{EditorView, ScrollView, $} = require 'atom'
{Emitter} = require 'emissary'
Debug = require 'prolix'

module.exports =
class MinimapPaneView extends ScrollView
  Emitter.includeInto(this)
  Debug('minimap').includeInto(this)

  @content: ->
    @div class: 'minimap-editor editor editor-colors', =>
      @div class: 'scroll-view', outlet: 'scrollView', =>
        @div class: 'lines', outlet: 'lines'

  lineOverdraw: 10
  frameRequested: false

  constructor: ->
    super
    @pendingChanges = []

  initialize: ->
    @lines.css 'line-height', atom.config.get('editor.lineHeight') + 'em'
    atom.config.observe 'editor.lineHeight', =>
      @lines.css 'line-height', atom.config.get('editor.lineHeight') + 'em'

  destroy: ->
    @unsubscribe()
    @editorView = null

  setEditorView: (@editorView) ->
    @editor = @editorView.getModel()
    @buffer = @editorView.getEditor().buffer

    # @subscribe @buffer, 'changed', @registerBufferChanges
    @subscribe @editor, 'screen-lines-changed.minimap', (changes) =>
      @pendingChanges.push changes
      @requestUpdate()

  requestUpdate: ->
    return if @frameRequested
    @frameRequested = true

    setImmediate =>
      @startBench()
      @update()
      @endBench('minimpap update')
      @frameRequested = false

  scrollTop: (scrollTop, options={}) ->
    return @cachedScrollTop or 0 unless scrollTop?
    return if scrollTop is @cachedScrollTop

    @cachedScrollTop = scrollTop
    @requestUpdate()

  registerBufferChanges: (event) =>
    @pendingChanges.push event

  getHeight: -> @getLinesCount() * @getLineHeight()
  getLineHeight: -> @lineHeight ||= parseInt @editorView.css('line-height')
  getLinesCount: -> @editorView.getEditor().getScreenLineCount()

  getMinimapScreenHeight: -> @minimapView.height() / @minimapView.scaleY
  getMinimapHeightInLines: -> Math.ceil(@getMinimapScreenHeight() / @getLineHeight())

  getFirstVisibleScreenRow: ->
    screenRow = Math.floor(@scrollTop() / @getLineHeight())
    screenRow = 0 if isNaN(screenRow)
    screenRow

  getLastVisibleScreenRow: ->
    calculatedRow = Math.ceil((@scrollTop() + @getMinimapScreenHeight()) / @getLineHeight()) - 1
    screenRow = Math.max(0, Math.min(@editor.getScreenLineCount() - 1, calculatedRow))
    screenRow = 0 if isNaN(screenRow)
    screenRow

  update: =>
    return unless @editorView?

    firstVisibleScreenRow = @getFirstVisibleScreenRow()
    lastScreenRowToRender = firstVisibleScreenRow + @getMinimapHeightInLines() - 1
    lastScreenRow = @editor.getLastScreenRow()

    @lines.css fontSize: "#{@editorView.getFontSize()}px"

    if @firstRenderedScreenRow? and firstVisibleScreenRow >= @firstRenderedScreenRow and lastScreenRowToRender <= @lastRenderedScreenRow
      renderFrom = Math.min(lastScreenRow, @firstRenderedScreenRow)
      renderTo = Math.min(lastScreenRow, @lastRenderedScreenRow)
    else
      renderFrom = Math.min(lastScreenRow, Math.max(0, firstVisibleScreenRow - @lineOverdraw))
      renderTo = Math.min(lastScreenRow, lastScreenRowToRender + @lineOverdraw)

    if @pendingChanges.length == 0 and @firstRenderedScreenRow and @firstRenderedScreenRow <= renderFrom and renderTo <= @lastRenderedScreenRow
      return

    changes = @pendingChanges
    intactRanges = @computeIntactRanges(renderFrom, renderTo)

    @clearDirtyRanges(intactRanges)
    @fillDirtyRanges(intactRanges, renderFrom, renderTo)
    @firstRenderedScreenRow = renderFrom
    @lastRenderedScreenRow = renderTo
    @updatePaddingOfRenderedLines()
    @emit 'minimap:updated'

   computeIntactRanges: (renderFrom, renderTo) ->
    return [] if !@firstRenderedScreenRow? and !@lastRenderedScreenRow?

    intactRanges = [{start: @firstRenderedScreenRow, end: @lastRenderedScreenRow, domStart: 0}]

    if @editorView.showIndentGuide
      emptyLineChanges = []
      for change in @pendingChanges
        changes = @computeSurroundingEmptyLineChanges(change)
        emptyLineChanges.push(changes...)

      @pendingChanges.push(emptyLineChanges...)

    for change in @pendingChanges
      newIntactRanges = []
      for range in intactRanges
        if change.end < range.start and change.screenDelta != 0
          newIntactRanges.push(
            start: range.start + change.screenDelta
            end: range.end + change.screenDelta
            domStart: range.domStart
          )
        else if change.end < range.start or change.start > range.end
          newIntactRanges.push(range)
        else
          if change.start > range.start
            newIntactRanges.push(
              start: range.start
              end: change.start - 1
              domStart: range.domStart)
          if change.end < range.end
            newIntactRanges.push(
              start: change.end + change.screenDelta + 1
              end: range.end + change.screenDelta
              domStart: range.domStart + change.end + 1 - range.start
            )

      intactRanges = newIntactRanges

    @truncateIntactRanges(intactRanges, renderFrom, renderTo)

    @pendingChanges = []

    intactRanges

  truncateIntactRanges: (intactRanges, renderFrom, renderTo) ->
    i = 0
    while i < intactRanges.length
      range = intactRanges[i]
      if range.start < renderFrom
        range.domStart += renderFrom - range.start
        range.start = renderFrom
      if range.end > renderTo
        range.end = renderTo
      if range.start >= range.end
        intactRanges.splice(i--, 1)
      i++
    intactRanges.sort (a, b) -> a.domStart - b.domStart

  computeSurroundingEmptyLineChanges: (change) ->
    emptyLineChanges = []

    if change.bufferDelta?
      afterStart = change.end + change.bufferDelta + 1
      if @editor.lineForBufferRow(afterStart) is ''
        afterEnd = afterStart
        afterEnd++ while @editor.lineForBufferRow(afterEnd + 1) is ''
        emptyLineChanges.push({start: afterStart, end: afterEnd, screenDelta: 0})

      beforeEnd = change.start - 1
      if @editor.lineForBufferRow(beforeEnd) is ''
        beforeStart = beforeEnd
        beforeStart-- while @editor.lineForBufferRow(beforeStart - 1) is ''
        emptyLineChanges.push({start: beforeStart, end: beforeEnd, screenDelta: 0})

    emptyLineChanges

  clearDirtyRanges: (intactRanges) ->
    if intactRanges.length == 0
      @lines[0].innerHTML = ''
    else if currentLine = @lines[0].firstChild
      domPosition = 0
      for intactRange in intactRanges
        while intactRange.domStart > domPosition
          currentLine = @clearLine(currentLine)
          domPosition++

        for i in [intactRange.start..intactRange.end]
          currentLine = currentLine.nextSibling
          domPosition++

      while currentLine
        currentLine = @clearLine(currentLine)

  clearLine: (lineElement) ->
    next = lineElement.nextSibling
    @lines[0].removeChild(lineElement)
    next


  fillDirtyRanges: (intactRanges, renderFrom, renderTo) ->
    i = 0
    nextIntact = intactRanges[i]
    currentLine = @lines[0].firstChild

    row = renderFrom
    while row <= renderTo
      if row == nextIntact?.end + 1
        nextIntact = intactRanges[++i]

      if !nextIntact or row < nextIntact.start
        if nextIntact
          dirtyRangeEnd = nextIntact.start - 1
        else
          dirtyRangeEnd = renderTo

        for lineElement in @editorView.buildLineElementsForScreenRows(row, dirtyRangeEnd)
          @lines[0].insertBefore(lineElement, currentLine)
          row++
      else
        currentLine = currentLine?.nextSibling
        row++

  updatePaddingOfRenderedLines: ->
    paddingTop = @firstRenderedScreenRow * @lineHeight
    @lines.css('padding-top', paddingTop)

    paddingBottom = (@editor.getLastScreenRow() - @lastRenderedScreenRow) * @lineHeight
    @lines.css('padding-bottom', paddingBottom)

  getClientRect: ->
    sv = @scrollView[0]
    {
      width: sv.scrollWidth,
      height: sv.scrollHeight
    }
