local callbacks = require("@self/callbacks")
local mockdatastoreservice = require("@self/mockdatastoreservice")
local schema = require("@self/schema")
local store = require("@self/store")

export type Schema<T> = schema.Schema<T>
export type Store<T> = store.Store<T>

return table.freeze {
	callbacks = callbacks,
	mockdatastoreservice = mockdatastoreservice,

	schema = schema.create,
	migrate = schema.migrate,

	store = store.create,
	startsession = store.startsession,
	waitforsession = store.waitforsession,
	issessionactive = store.issessionactive,
	closeasync = store.closeasync,
	stopsessionasync = store.stopsessionasync,
	view = store.view,
	update = store.update,
	observe = store.observe,
	viewasync = store.viewasync,
	updateasync = store.updateasync,
	txasync = store.txasync,
}
