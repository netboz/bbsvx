ontology(root).   %% Thing is the root class from which all derive 
isa(thing, thing).  
relation(isa(Child, Ancestor)).

%% Transitive isa rule
isa(Child, Ancestor) :-
    isa(Child, Father),
    isa(Father, Ancestor),
    Child \= Father,  % Prevent infinite loops
    Father \= Ancestor.
instantiable(thing).      
have_attribute(thing, name).  

action(assert(instance_of(InstabceName, ThingOrChildThingClass)), [isa(InstanceName, thing), create_instance(ThingOrChildThingClass, InstanceName)], 
    instance_of(ThingOrChildThingClass, InstanceName)).

%%  Define ontology type

isa(ontology, thing).
  %% Action to trigger ontology creation
action(create_ontology_predicate(OntologyName, shared),
         [],
         instance_of(ontology, OntologyName)).



%% Define event type 
isa(event, thing).  
have_attribute(event, timestamp). 
have_attribute(event, duration). 
have_attribute(event, emitted). 
relation(subscribed_to(EventPattern)).  

emitted(event, Event) :-     
   false.  

subscribed(Thing, EventPattern) :-     
   subscribed_predicate(Thing, EventPattern).  

action(emit_event_predicate(Event), [], emitted(Event)).  
action(subscribe_event_predicate(EventPattern), [], subscribed(EventPattern)).  
action(unsubscribe_event_predicate(EventPattern), [], unsubscribed(EventPattern)).  

%% Define a bbsvx node  
isa(node, thing). 
have_attribute(node, node_ip). 
have_attribute(node, node_id).  

node_ip(Node, NodeIp) :-     
   instance_of(node, Node),     
   node_ip_predicate(NodeIp).  

node_id(Node, NodeId) :-     
   instance_of(node, Node),     
   node_id_predicate(NodeId).  

relation(connected_to(node)).  

connected_to(Node) :-     
   instance_of(node,Node),     
   is_connected_to_predicate(Node).  

not_connected_to(Node) :-     
   \+connected_to(Node).  

action(connect_predicate(Node), [instance_of(node, Node), not_connected_to(Node)], connected_to(Node)). 
action(disconnect(Node), [connected_to(Node)], not_connected_to(Node)).


%% Define a visible object
isa(visible_thing, thing).
have_attribute(visible, position).      % 3D coordinates
have_attribute(visible, rotation).      % 3D rotation
have_attribute(visible, scale).         % 3D scale
have_attribute(visible, mesh_type).     % sphere, box, custom, etc.
have_attribute(visible, material).      % color, texture, shader
have_attribute(visible, visibility).    % true/false