extends RefCounted
class_name EvolutionModel

# evo dict format:
# {
#   "chain_id": int,
#   "root_species_id": int,
#   "nodes": { species_id: {"id":int,"name":String} },
#   "children": { species_id: Array[int] },
#   "edge_details": { "from->to": Array[Dictionary] }   # triggers/conditions REST
# }

static func build_from_db(species_id: int) -> Dictionary:
	# 1) lire pokemon_species pour trouver chain_id
	var s := PokeDb.get_entity("pokemon_species", species_id)
	if s.is_empty():
		return {}

	var chain_id := int(s.get("evolution_chain_id", -1))
	if chain_id <= 0:
		return {}

	# 2) lire la chain REST déjà importée en DB
	var chain := PokeDb.get_entity("evolution_chain_rest", chain_id)
	if chain.is_empty():
		return {} # (ton onglet peut dire "pas de data", ou tu peux déclencher un download côté Update)

	var root_node_v :Variant= chain.get("chain", null)
	if root_node_v == null or typeof(root_node_v) != TYPE_DICTIONARY:
		return {}

	var nodes := {}
	var children := {}
	var edge_details := {}

	# init: on crée les keys de children au fur et à mesure
	_walk_rest_chain(root_node_v as Dictionary, -1, nodes, children, edge_details)

	var root_species := _species_id_from_node(root_node_v as Dictionary)
	if root_species <= 0:
		root_species = species_id

	# tri stable des enfants
	for k in children.keys():
		(children[k] as Array).sort()

	return {
		"chain_id": chain_id,
		"root_species_id": root_species,
		"nodes": nodes,
		"children": children,
		"edge_details": edge_details
	}

static func _walk_rest_chain(node: Dictionary, parent_species_id: int, nodes: Dictionary, children: Dictionary, edge_details: Dictionary) -> void:
	var sid := _species_id_from_node(node)
	if sid <= 0:
		return

	var sname := _species_name_from_node(node)

	if not nodes.has(sid):
		nodes[sid] = {"id": sid, "name": sname}

	if not children.has(sid):
		children[sid] = []

	# si on a un parent, on relie parent -> sid
	if parent_species_id > 0:
		if not children.has(parent_species_id):
			children[parent_species_id] = []
		(children[parent_species_id] as Array).append(sid)

		# Les conditions d'évolution sont sur LE NOEUD ENFANT dans le JSON REST
		var dets_v :Variant= node.get("evolution_details", [])
		if typeof(dets_v) == TYPE_ARRAY:
			var key := "%d->%d" % [parent_species_id, sid]
			edge_details[key] = dets_v

	# recurse
	var evolves_to_v :Variant= node.get("evolves_to", [])
	if typeof(evolves_to_v) != TYPE_ARRAY:
		return

	for child_any in (evolves_to_v as Array):
		if typeof(child_any) != TYPE_DICTIONARY:
			continue
		_walk_rest_chain(child_any as Dictionary, sid, nodes, children, edge_details)

static func _species_id_from_node(node: Dictionary) -> int:
	var sp :Variant= node.get("species", null)
	if sp == null or typeof(sp) != TYPE_DICTIONARY:
		return -1
	var url := str((sp as Dictionary).get("url", ""))
	return _id_from_url(url)

static func _species_name_from_node(node: Dictionary) -> String:
	var sp :Variant= node.get("species", null)
	if sp == null or typeof(sp) != TYPE_DICTIONARY:
		return ""
	return str((sp as Dictionary).get("name", ""))

static func _id_from_url(url: String) -> int:
	var s := url.strip_edges()
	if s.is_empty():
		return -1
	if s.ends_with("/"):
		s = s.substr(0, s.length() - 1)
	var parts := s.split("/")
	if parts.is_empty():
		return -1
	return int(parts[parts.size() - 1])
