%% =============================================================================
%% BBSvx Root Ontology
%% Defines the base class hierarchy that all ontologies inherit from
%% =============================================================================

ontology(root).

%% =============================================================================
%% Root Class: thing
%% All classes derive from thing
%% =============================================================================

%% thing is the root - it is its own parent (reflexive base case)
isa(thing, thing).

%% Transitive isa rule for class hierarchy
isa(Child, Ancestor) :-
    isa(Child, Father),
    isa(Father, Ancestor),
    Child \= Father,
    Father \= Ancestor.

%% All things can have a name
have_attribute(thing, name).

%% =============================================================================
%% Ontology Class
%% Represents a namespace/ontology as a first-class entity
%% =============================================================================

isa(ontology, thing).

action(create_ontology_predicate(OntologyName, shared),
    [],
    instance_of(ontology, OntologyName)).

%% =============================================================================
%% Event Class
%% For pub/sub event handling
%% =============================================================================

isa(event, thing).
have_attribute(event, timestamp).
have_attribute(event, duration).

%% Event emission and subscription
action(emit_event(Event), [], emitted(Event)).
action(subscribe_event(EventPattern), [], subscribed(EventPattern)).
action(unsubscribe_event(EventPattern), [], unsubscribed(EventPattern)).

%% =============================================================================
%% Visible Thing Class (Effect Layer)
%% Base class for all entities that can be rendered in 3D space
%% =============================================================================

isa(visible_thing, thing).
have_attribute(visible_thing, position).      %% vec3(X, Y, Z)
have_attribute(visible_thing, rotation).      %% vec3(RX, RY, RZ) in radians
have_attribute(visible_thing, scale).         %% vec3(SX, SY, SZ)
have_attribute(visible_thing, mesh_type).     %% sphere, box, custom, generated
have_attribute(visible_thing, material).      %% color, texture reference
have_attribute(visible_thing, visibility).    %% true/false

%% =============================================================================
%% Animal Class Hierarchy
%% Example domain classes
%% =============================================================================

isa(animal, visible_thing).
isa(rabbit, animal).
isa(dog, animal).
isa(lion, animal).
isa(wolf, animal).
isa(fox, animal).

%% =============================================================================
%% Test Instances
%% Example animal instances for testing the ontology system
%% =============================================================================

%% A family of rabbits
instance_of(rabbit, bunny).
attribute(bunny, position, vec3(-5, 0, 0)).
attribute(bunny, name, 'Bunny the Rabbit').

instance_of(rabbit, fluffy).
attribute(fluffy, position, vec3(-3, 0, 2)).
attribute(fluffy, name, 'Fluffy').

%% Some dogs
instance_of(dog, rex).
attribute(rex, position, vec3(5, 0, 0)).
attribute(rex, name, 'Rex the Dog').

instance_of(dog, spot).
attribute(spot, position, vec3(7, 0, -2)).
attribute(spot, name, 'Spot').

%% A lion
instance_of(lion, simba).
attribute(simba, position, vec3(0, 0, 10)).
attribute(simba, name, 'Simba the Lion').

%% A wolf
instance_of(wolf, grey).
attribute(grey, position, vec3(-8, 0, -5)).
attribute(grey, name, 'Grey Wolf').

%% A fox
instance_of(fox, foxy).
attribute(foxy, position, vec3(10, 0, 5)).
attribute(foxy, name, 'Foxy').
