extends Control
class_name EvoPage

signal pokemon_selected(pokemon_id: int, species_id: int)

@onready var graph: EvolutionGraph = $Root/EvolutionGraph
@onready var lbl_debug: Label = $Root/Header/Debug

var _species_id := 0
var _pokemon_id := 0

func _ready() -> void:
	# quand un node est cliqué dans le graphe
	graph.pokemon_selected.connect(_on_graph_pokemon_selected)

func render_species(species_id: int, pokemon_id: int = 0) -> void:
	_species_id = species_id
	_pokemon_id = pokemon_id

	if lbl_debug:
		lbl_debug.text = ""

	# build data depuis DB
	var evo := EvolutionModel.build_from_db(species_id)
	if evo.is_empty():
		# rien à afficher (ton PokemonDetails peut cacher l’onglet)
		graph.clear()
		if lbl_debug:
			lbl_debug.text = "Aucune donnée."
		return

	graph.render(evo, species_id)

func _on_graph_pokemon_selected(pokemon_id: int, species_id: int) -> void:
	emit_signal("pokemon_selected", pokemon_id, species_id)
