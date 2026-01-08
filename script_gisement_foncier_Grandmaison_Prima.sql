\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';

--- Étudiant Geonum 2026: 
-- Grandmaison Roland
-- Prima Olivier

-- Création d'un schéma de travail pour éviter de perdre les données de base
CREATE SCHEMA If NOT EXISTS gst_grandmaison_prima;


----------------------------------------------------------------------------------------------------------
-- PARTIE 0 : Couche de préparation
--- Récupération de l'EPCI
DROP TABLE IF EXISTS gst_grandmaison_prima.epci_capi;
CREATE TABLE gst_grandmaison_prima.epci_capi AS
	SELECT 
		com.codgeo, -- Identification de la commune
		com.libgeo, -- Nom de la commune
		com.geom -- Géométrie
	FROM
		geonum_reference.commune AS com
	WHERE com.epci = '243800604'
;

create index in_epci_capi on gst_grandmaison_prima.epci_capi using gist(geom);

--- Couche des communes sans PLU qui se soumettent au RNU (règlement national d'urbanisme)
DROP TABLE IF EXISTS gst_grandmaison_prima.rnu;
CREATE TABLE gst_grandmaison_prima.rnu AS
	SELECT 
		com.codgeo, -- Identification de la commune
		com.libgeo, -- Nom de la commune
		com.geom -- Géométrie
	FROM
		geonum_reference.commune AS com
	WHERE com.codgeo = '38152' OR com.codgeo = '38530' -- communes sans documents d'urbanisme
;

create index in_rnu on gst_grandmaison_prima.rnu using gist(geom);


----------------------------------------------------------------------------------------------------------
-- PARTIE 1 : Création du masque bâtiment
--- Récupération des bâtiments sur les communes de la CAPI
DROP TABLE IF EXISTS gst_grandmaison_prima.bat_capi;
CREATE TABLE gst_grandmaison_prima.bat_capi AS
	SELECT
		CASE
			WHEN ST_Area(bat.geom) < 50 THEN ST_Buffer(bat.geom,2) -- Si la superficie du bâtiment est inéfieur à 50m², alors tampon de 2 mètres
			ELSE ST_Buffer(bat.geom,50) -- Tous les autres bâtiment, un tampon de 50 mètres
			END AS geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.bdtopo_batiment as bat on ST_Intersects(com.geom, bat.geom)
;

create index in_bat_capi on gst_grandmaison_prima.bat_capi using gist(geom);

--- Fusionner les tampon pour en faire une géométrie unique
DROP TABLE IF EXISTS gst_grandmaison_prima.bat_u_capi;
CREATE TABLE gst_grandmaison_prima.bat_u_capi AS
	SELECT
		ST_Union(bat.geom) as geom
	FROM
		gst_grandmaison_prima.bat_capi as bat
;

create index in_bat_u_capi on gst_grandmaison_prima.bat_u_capi using gist(geom);

--- Suppression de la table bat_capi devenue obselète
DROP TABLE gst_grandmaison_prima.bat_capi;


----------------------------------------------------------------------------------------------------------
-- PARTIE 2 : Création du masque infrastructure linéaire
--- Récupération des linéaires sur les communes de la CAPI
---- En premier lieu les routes
DROP TABLE IF EXISTS gst_grandmaison_prima.route_capi;
CREATE TABLE gst_grandmaison_prima.route_capi AS	
	SELECT
		CASE
			WHEN route.highway = 'motorway' THEN ST_Buffer(st_intersection(route.geom, com.geom),15)
			WHEN route.highway = 'motorway_link' THEN ST_Buffer(st_intersection(route.geom, com.geom),15)
			WHEN route.highway = 'primary' THEN ST_Buffer(st_intersection(route.geom, com.geom),15)
			WHEN route.highway = 'primary_link' THEN ST_Buffer(st_intersection(route.geom, com.geom),15)
			WHEN route.highway = 'secondary' THEN ST_Buffer(st_intersection(route.geom, com.geom),7)
			WHEN route.highway = 'tertiary' THEN ST_Buffer(st_intersection(route.geom, com.geom),7)
			WHEN route.highway = 'residential' THEN ST_Buffer(st_intersection(route.geom, com.geom),7)
			WHEN route.highway = 'unclassified' THEN ST_Buffer(st_intersection(route.geom, com.geom),7)
			ELSE ST_Buffer(st_intersection(route.geom, com.geom),0)
			END AS geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.osm_road as route on ST_Intersects(com.geom, route.geom)
;

create index in_route_capi on gst_grandmaison_prima.route_capi using gist(geom);

---- En second lieu le rail
DROP TABLE IF EXISTS gst_grandmaison_prima.rail_capi;
CREATE TABLE gst_grandmaison_prima.rail_capi AS	
	SELECT
		ST_Buffer(st_intersection(rail.geom, com.geom),15) as geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.osm_railway as rail on ST_Intersects(com.geom, rail.geom)
;

create index in_rail_capi on gst_grandmaison_prima.rail_capi using gist(geom);

--- Fusionner les deux tables
DROP TABLE IF EXISTS gst_grandmaison_prima.frr_capi;
CREATE TABLE gst_grandmaison_prima.frr_capi AS	
	SELECT *
		FROM gst_grandmaison_prima.route_capi
	UNION
	SELECT *
		FROM gst_grandmaison_prima.rail_capi
;

create index in_frr_capi on gst_grandmaison_prima.frr_capi using gist(geom);

--- Regrouper les géométries
DROP TABLE IF EXISTS gst_grandmaison_prima.lineaire_capi;
CREATE TABLE gst_grandmaison_prima.lineaire_capi AS
	SELECT
		ST_Union(frr.geom) as geom
	FROM
		gst_grandmaison_prima.frr_capi as frr
;

create index in_lineaire_capi on gst_grandmaison_prima.lineaire_capi using gist(geom);

--- Suppression des tables intermédiaire devenues inutles
DROP TABLE gst_grandmaison_prima.frr_capi;
DROP TABLE gst_grandmaison_prima.rail_capi;


----------------------------------------------------------------------------------------------------------
-- PARTIE 3 : Création du masque équipement
--- Création d'une table par équipement
---- Surface en eau de OSM
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_eau_capi;
CREATE TABLE gst_grandmaison_prima.osm_eau_capi AS	
	SELECT
		st_intersection(eau.geom, com.geom) as geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.osm_water as eau on ST_Intersects(com.geom, eau.geom)
;

create index in_osm_eau_capi on gst_grandmaison_prima.osm_eau_capi using gist(geom);

---- Équipement sportif OSM
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_sport_capi;
CREATE TABLE gst_grandmaison_prima.osm_sport_capi AS	
	SELECT
		ST_Buffer(st_intersection(sport.geom, com.geom),1) as geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.osm_sport_center as sport on ST_Intersects(com.geom, sport.geom)
;

create index in_osm_sport_capi on gst_grandmaison_prima.osm_sport_capi using gist(geom);

---- Équipement scolaire OSM
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_ecole_capi;
CREATE TABLE gst_grandmaison_prima.osm_ecole_capi AS	
	SELECT
		ST_Buffer(st_intersection(ecole.geom, com.geom),1) as geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.osm_school as ecole on ST_Intersects(com.geom, ecole.geom)
;

create index in_osm_ecole_capi on gst_grandmaison_prima.osm_ecole_capi using gist(geom);

---- Parc OSM
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_parc_capi;
CREATE TABLE gst_grandmaison_prima.osm_parc_capi AS	
	SELECT
		st_intersection(parc.geom, com.geom) as geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.osm_park as parc on ST_Intersects(com.geom, parc.geom)
;

create index in_osm_parc_capi on gst_grandmaison_prima.osm_parc_capi using gist(geom);

---- Poste de transformation électrique BD_Topo
DROP TABLE IF EXISTS gst_grandmaison_prima.topo_elec_capi;
CREATE TABLE gst_grandmaison_prima.topo_elec_capi AS	
	SELECT
		st_intersection(elec.geom, com.geom) as geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.bdtopo_poste_de_transformation as elec on ST_Intersects(com.geom, elec.geom)
;

create index in_topo_elec_capi on gst_grandmaison_prima.topo_elec_capi using gist(geom);

---- Cimetière BD_Topo
DROP TABLE IF EXISTS gst_grandmaison_prima.topo_cim_capi;
CREATE TABLE gst_grandmaison_prima.topo_cim_capi AS	
	SELECT
		st_intersection(cim.geom, com.geom) as geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.bdtopo_cimetiere as cim on ST_Intersects(com.geom, cim.geom)
;

create index in_topo_cim_capi on gst_grandmaison_prima.topo_cim_capi using gist(geom);

---- Cimetière OSM
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_cim_capi;
CREATE TABLE gst_grandmaison_prima.osm_cim_capi AS	
	SELECT
		st_intersection(cim.geom, com.geom) as geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.bdtopo_cimetiere as cim on ST_Intersects(com.geom, cim.geom)
;

create index in_osm_cim_capi on gst_grandmaison_prima.osm_cim_capi using gist(geom);

---- Aérodrome BD_Topo
DROP TABLE IF EXISTS gst_grandmaison_prima.bdtopo_aerodrome;
CREATE TABLE gst_grandmaison_prima.bdtopo_aerodrome AS	
	SELECT
		st_intersection(aero.geom, com.geom) as geom
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.bdtopo_aerodrome as aero on ST_Intersects(com.geom, aero.geom)
;

create index in_bdtopo_aerodrome on gst_grandmaison_prima.bdtopo_aerodrome using gist(geom);

--- "Fusionner" les tables pour n'en faire qu'une seule table équipement
DROP TABLE IF EXISTS gst_grandmaison_prima.u_equip_capi;
CREATE TABLE gst_grandmaison_prima.u_equip_capi AS	
	SELECT *
		FROM gst_grandmaison_prima.osm_eau_capi
	UNION
	SELECT *
		FROM gst_grandmaison_prima.osm_sport_capi
	UNION
	SELECT *
		FROM gst_grandmaison_prima.osm_ecole_capi
	UNION
	SELECT *
		FROM gst_grandmaison_prima.osm_parc_capi
	UNION
	SELECT *
		FROM gst_grandmaison_prima.topo_elec_capi
	UNION
	SELECT *
		FROM gst_grandmaison_prima.topo_cim_capi
	UNION
	SELECT *
		FROM gst_grandmaison_prima.osm_cim_capi
	UNION
	SELECT *
		FROM gst_grandmaison_prima.bdtopo_aerodrome
;

create index in_u_equip_capi on gst_grandmaison_prima.u_equip_capi using gist(geom);

--- Dans la table équipement, grouper les géométries pour n'en faire qu'une seule
--- Utilisation de ST_buffer et de ST_Force2D afin de gérer les mauvaises géométries
--- comme les données ponctuelles.
DROP TABLE IF EXISTS gst_grandmaison_prima.equipement_capi;
CREATE TABLE gst_grandmaison_prima.equipement_capi AS
	SELECT
		ST_Buffer(ST_Buffer(ST_Union(ST_Force2D(uequip.geom)),-1),1) as geom
	FROM
		gst_grandmaison_prima.u_equip_capi as uequip
;

create index in_equipement_capi on gst_grandmaison_prima.equipement_capi using gist(geom);

--- Supprimer les tables des équipements séparés qui sont devenues inutiles
DROP TABLE IF EXISTS gst_grandmaison_prima.u_equip_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_eau_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_sport_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_ecole_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_parc_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.topo_elec_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.topo_cim_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.osm_cim_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.bdtopo_aerodrome;


----------------------------------------------------------------------------------------------------------
-- PARTIE 4 : Identification des parcelles candidates
--- Récupération des secteurs de PLU en U ou AU sur les communes de la CAPI
DROP TABLE IF EXISTS gst_grandmaison_prima.plu_capi;
CREATE TABLE gst_grandmaison_prima.plu_capi AS
	SELECT 
		com.codgeo, -- identification de la commune
		zurba.typezone, -- identification du type de zone d'urbanisme (U/AU)
		zurba.libelle, -- identification des sous zonage (Ua, Ub, AUa...)
		zurba.libelong, -- degst_grandmaison_primaion précise du libelle
		zurba.geom -- geométrie du zonage PLU
	FROM
		gst_grandmaison_prima.epci_capi AS com
		INNER JOIN geonum_reference.zonage_urbanisme as zurba on ST_Intersects(com.geom, zurba.geom)
	WHERE (zurba.typezone LIKE 'U%' OR zurba.typezone LIKE 'AU%') AND zurba.libelle NOT LIKE 'UP'
;

create index in_plucapi on gst_grandmaison_prima.plu_capi using gist(geom);


---- La tâche urbaine ici présente est de 20 mètres autour des bâtiments de la BD Topo, plus les tampons du linéaire des routes.
---- Nous réalisons pour cela une dilatation-érosion. La dilatation est de 50 mètres afin de prendre tout les bâtiments à proximité.
---- Cette dilatation est suivie d'une érosion de 30 mètres afin que la tâche urbaine soit un tampon de 20 mètres.
---- Cette érosion-dilatation est une solution commune à de nombreux territoires qui l'utilise ou l'ont utilisée avant l'arrivée de l'OCSGE.
---- Si nous avons choisi de ne pas utiliser l'OCSGE, cela est dû à l'absence de confirmation que celle-ci serait mise à jour.
---- Nous avons donc privilégié les bâtiments BD Topo de l'IGN qui est mise à jour chaque année.

--- Création de la tâche urbaine pour les communes sans documents d'urbanisme (communes au RNU (Règlement National d'Urbanisme))
DROP TABLE IF EXISTS gst_grandmaison_prima.bta_capi;
CREATE TABLE gst_grandmaison_prima.bta_capi AS
	SELECT
		(ST_dump(ST_Buffer(ST_Union(ST_Buffer(bat.geom,50)),-30))).geom as geom
	FROM
		gst_grandmaison_prima.rnu AS rnu
		INNER JOIN geonum_reference.bdtopo_batiment as bat on ST_Intersects(rnu.geom, bat.geom)
;

create index in_bta_capi on gst_grandmaison_prima.bta_capi using gist(geom);



--- Union des bâtiments (tampon 20 mètres) et routes pour la tâche urbaine
DROP TABLE IF EXISTS gst_grandmaison_prima.brta_capi;
CREATE TABLE gst_grandmaison_prima.brta_capi AS
	SELECT
		bta.geom
		FROM gst_grandmaison_prima.bta_capi as bta
	UNION
	SELECT
		route.geom
		FROM gst_grandmaison_prima.route_capi as route
;

create index in_brta on gst_grandmaison_prima.brta_capi using gist(geom);

--- suppression de couches
DROP TABLE gst_grandmaison_prima.bta_capi;
DROP TABLE gst_grandmaison_prima.route_capi;

--- Retrait des zones de tâche urbaine en dehors des communes concernées (sauf erreur de calage)
DROP TABLE IF EXISTS gst_grandmaison_prima.ta_capi;
CREATE TABLE gst_grandmaison_prima.ta_capi AS
	SELECT
		ST_union(st_intersection(brta.geom, rnu.geom)) as geom
	FROM
		gst_grandmaison_prima.rnu AS rnu
		INNER JOIN gst_grandmaison_prima.brta_capi as brta on ST_Intersects(rnu.geom, brta.geom)
;

create index in_ta_capi on gst_grandmaison_prima.ta_capi using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.brta_capi;

--- Union des géométries des plu
DROP TABLE IF EXISTS gst_grandmaison_prima.plu_u;
CREATE TABLE gst_grandmaison_prima.plu_u AS
SELECT
	(ST_Dump(ST_Union(plu.geom))).geom AS geom
	FROM 
		gst_grandmaison_prima.plu_capi AS plu
;

create index in_plu_u on gst_grandmaison_prima.plu_u using gist(geom);

--- suppression de la tâche urbaine des zones PLU constructibles des communes adjacentes.
DROP TABLE IF EXISTS gst_grandmaison_prima.ta_a;
CREATE TABLE gst_grandmaison_prima.ta_a AS
SELECT
	(ST_Dump(ST_Difference(ta.geom, plu_u.geom))).geom AS geom
	FROM 
		gst_grandmaison_prima.ta_capi AS ta
		INNER JOIN gst_grandmaison_prima.plu_u AS plu_u on ST_Intersects(ta.geom, plu_u.geom)
;

create index in_ta_a on gst_grandmaison_prima.ta_a using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.ta_capi;

--- Ajout des identifiants
DROP TABLE IF EXISTS gst_grandmaison_prima.tache_urbaine;
CREATE TABLE gst_grandmaison_prima.tache_urbaine AS
	SELECT
	rnu.codgeo,
	rnu.libgeo,
	ST_intersection(ta_a.geom, rnu.geom) as geom -- buffer pour retirer les erreurs de geometrie
	FROM
		gst_grandmaison_prima.ta_a AS ta_a
		INNER JOIN gst_grandmaison_prima.rnu AS rnu on ST_intersects(ta_a.geom, rnu.geom)
;

ALTER TABLE gst_grandmaison_prima.tache_urbaine
ADD COLUMN idtache SERIAL PRIMARY KEY;

create index in_tache_urbaine on gst_grandmaison_prima.tache_urbaine using gist(geom);

--- suppression des tables devenues inutiles
DROP TABLE IF EXISTS gst_grandmaison_prima.ta_a;

--- Création couche des zonages PLU + tâche urbaine (avec risque de chevauchement)
DROP TABLE IF EXISTS gst_grandmaison_prima.plu_ta;
CREATE TABLE gst_grandmaison_prima.plu_ta AS
	SELECT
		plu.geom
		FROM gst_grandmaison_prima.plu_u as plu
	UNION
	SELECT
		ta.geom
		FROM gst_grandmaison_prima.tache_urbaine as ta
;

create index in_plu_ta on gst_grandmaison_prima.plu_ta using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.plu_u;

--- Récupération des Parcelles qui sont dans les zonages PLU ou tâche urbaine
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_plu_capi;
CREATE TABLE gst_grandmaison_prima.parcelles_plu_capi AS
	SELECT
	ST_Union(ST_intersection(ST_MakeValid(par.geom), plu.geom)) as geom
	FROM
		geonum_reference.parcelles AS par
		INNER JOIN gst_grandmaison_prima.plu_ta as plu on ST_intersects(par.geom, plu.geom)
;

create index in_parcelles_plu_capi on gst_grandmaison_prima.parcelles_plu_capi using gist(geom);

--- Retirer des parcelles les zones tampons des bâtiments
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_bat_capi;
CREATE TABLE gst_grandmaison_prima.parcelles_bat_capi AS
SELECT
    ST_Union(ST_Difference(par.geom, bat.geom)) AS geom
	FROM 
		gst_grandmaison_prima.parcelles_plu_capi AS par,
		gst_grandmaison_prima.bat_u_capi AS bat
		WHERE ST_Intersects(par.geom, bat.geom)
;

create index in_parcelles_bat_capi on gst_grandmaison_prima.parcelles_bat_capi using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.bat_u_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_plu_capi;

--- Retirer des parcelles les zones tampons des linéaires
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_bat_lin_capi;
CREATE TABLE gst_grandmaison_prima.parcelles_bat_lin_capi AS
SELECT
    ST_Union(ST_Difference(par.geom, lin.geom)) AS geom
	FROM 
		gst_grandmaison_prima.parcelles_bat_capi AS par,
		gst_grandmaison_prima.lineaire_capi AS lin
		WHERE ST_Intersects(par.geom, lin.geom)
;

create index in_parcelles_bat_lin_capi on gst_grandmaison_prima.parcelles_bat_lin_capi using gist(geom);

--- suppression de couches
DROP TABLE gst_grandmaison_prima.parcelles_bat_capi;

--- Retirer les équipements
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_bat_lin_equi_capi;
CREATE TABLE gst_grandmaison_prima.parcelles_bat_lin_equi_capi AS
SELECT
    ST_Union(ST_Difference(par.geom, equip.geom)) AS geom
	FROM 
		gst_grandmaison_prima.parcelles_bat_lin_capi AS par,
		gst_grandmaison_prima.equipement_capi AS equip
		WHERE ST_Intersects(par.geom, equip.geom)
;

create index in_parcelles_bat_lin_equi_capi on gst_grandmaison_prima.parcelles_bat_lin_equi_capi using gist(geom);

--- suppression de couches
DROP TABLE gst_grandmaison_prima.parcelles_bat_lin_capi;


----------------------------------------------------------------------------------------------------------
-- Partie 5 : Identification du gisement non-bâti
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_non_bati_capi;
CREATE TABLE gst_grandmaison_prima.gisement_non_bati_capi AS
SELECT
	(ST_dump(gis.geom)).geom AS geom
	FROM 
		gst_grandmaison_prima.parcelles_bat_lin_equi_capi AS gis
;

create index in_gisement_non_bati_capi on gst_grandmaison_prima.gisement_non_bati_capi using gist(geom);

DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_nb_capi;
CREATE TABLE gst_grandmaison_prima.gisement_nb_capi AS
SELECT
	ST_Area(gis.geom),
	gis.geom
	FROM 
		gst_grandmaison_prima.gisement_non_bati_capi AS gis
	WHERE ST_Area(ST_buffer(ST_Buffer(gis.geom,-1),1)) >= 2000
;

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_bat_lin_equi_capi;

--- Créer une colonne type avec le type de gisement
ALTER TABLE gst_grandmaison_prima.gisement_nb_capi
ADD COLUMN typologie CHAR(25) DEFAULT 'non-bâti';

create index in_gisement_nb_capi on gst_grandmaison_prima.gisement_nb_capi using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_non_bati_capi;


----------------------------------------------------------------------------------------------------------
-- Partie 6 : Identification des gisements bâti
--- Ne conserver que les parcelles qui intersect le plu / la tâche urbaine
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_capi;
CREATE TABLE gst_grandmaison_prima.parcelles_capi AS
	SELECT
	par.geom
	FROM
		geonum_reference.parcelles AS par
		INNER JOIN gst_grandmaison_prima.plu_ta as pluta on ST_intersects(par.geom, pluta.geom)
;

create index in_parcelles_capi on gst_grandmaison_prima.parcelles_capi using gist(geom);

--- Récupérer les parcelles ayant un bâtiment
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_bat_capi;
CREATE TABLE gst_grandmaison_prima.parcelles_bat_capi AS
	SELECT
	par.geom,
	ST_area(par.geom) AS surface_par
	FROM
		gst_grandmaison_prima.parcelles_capi AS par
		INNER JOIN geonum_reference.bdtopo_batiment as bat on ST_intersects(par.geom, bat.geom)
;

create index in_parcelles_bat_capi on gst_grandmaison_prima.parcelles_bat_capi using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_capi;

--- Récupérer les bâtiments par parcelle (une parcelle peut avoir plusieurs bâtiments,
--- ici l'objectif est de calculer la surface de bâtiment par parcelle)
DROP TABLE IF EXISTS gst_grandmaison_prima.bat_par_capi;
CREATE TABLE gst_grandmaison_prima.bat_par_capi AS
	SELECT
		ST_intersection(ST_Union(bat.geom), par.geom) as geom
	FROM
		gst_grandmaison_prima.parcelles_bat_capi AS par
		JOIN geonum_reference.bdtopo_batiment as bat on ST_intersects(par.geom, bat.geom)
	GROUP BY par.geom
;

create index in_bat_par_capi on gst_grandmaison_prima.bat_par_capi using gist(geom);

--- Calcul du CES (Coefficient d'emprise au sol) par parcelle
DROP TABLE IF EXISTS gst_grandmaison_prima.ces_par_capi;
CREATE TABLE gst_grandmaison_prima.ces_par_capi AS
	SELECT
		par.geom,
		ST_Area(bat.geom)/par.surface_par as CES
	FROM
		gst_grandmaison_prima.parcelles_bat_capi AS par
		JOIN gst_grandmaison_prima.bat_par_capi as bat on ST_contains(par.geom, bat.geom)
	WHERE ST_Area(bat.geom)/par.surface_par <= 0.2
;

create index in_ces_par_capi on gst_grandmaison_prima.ces_par_capi using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.bat_par_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.parcelles_bat_capi;

--- Union des parcelles en gisement
DROP TABLE IF EXISTS gst_grandmaison_prima.par_u_capi;
CREATE TABLE gst_grandmaison_prima.par_u_capi AS
	SELECT
		ST_Union(par.geom) as geom
	FROM
		gst_grandmaison_prima.ces_par_capi AS par
;

create index in_par_u_capi on gst_grandmaison_prima.par_u_capi using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.ces_par_capi;

--- Retirer des parcelles les zones tampons des linéaires
DROP TABLE IF EXISTS gst_grandmaison_prima.par_u_lin_capi;
CREATE TABLE gst_grandmaison_prima.par_u_lin_capi AS
SELECT
    ST_Difference(par.geom, lin.geom) AS geom
	FROM 
		gst_grandmaison_prima.par_u_capi AS par,
		gst_grandmaison_prima.lineaire_capi AS lin
		WHERE ST_Intersects(par.geom, lin.geom)
;

create index in_par_u_lin_capi on gst_grandmaison_prima.par_u_lin_capi using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.par_u_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.lineaire_capi;

--- Retirer les équipements
DROP TABLE IF EXISTS gst_grandmaison_prima.par_u_lin_equip_capi;
CREATE TABLE gst_grandmaison_prima.par_u_lin_equip_capi AS
SELECT
    ST_Difference(par.geom, equip.geom) AS geom
	FROM 
		gst_grandmaison_prima.par_u_lin_capi AS par,
		gst_grandmaison_prima.equipement_capi AS equip
		WHERE ST_Intersects(par.geom, equip.geom)
;

create index in_par_u_lin_equip_capi on gst_grandmaison_prima.par_u_lin_equip_capi using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.equipement_capi;
DROP TABLE IF EXISTS gst_grandmaison_prima.par_u_lin_capi;

--- Retirer les gisements hors des zones constructible (PLU et tâche urbaine)
DROP TABLE IF EXISTS gst_grandmaison_prima.par_u_lin_equip_plu_capi;
CREATE TABLE gst_grandmaison_prima.par_u_lin_equip_plu_capi AS
SELECT
    (ST_dump(ST_intersection(par.geom, pluta.geom))).geom AS geom
	FROM 
		gst_grandmaison_prima.par_u_lin_equip_capi AS par,
		gst_grandmaison_prima.plu_ta AS pluta
		WHERE ST_Intersects(par.geom, pluta.geom)
;

create index in_par_u_lin_equip_plu_capi on gst_grandmaison_prima.par_u_lin_equip_plu_capi using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.plu_ta;
DROP TABLE IF EXISTS gst_grandmaison_prima.par_u_lin_equip_capi;

--- Calculer la surface des tènements
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_bati_s;
CREATE TABLE gst_grandmaison_prima.gisement_bati_s AS
SELECT
	ST_Area(gis.geom) AS surface_t,
	gis.geom
	FROM 
		gst_grandmaison_prima.par_u_lin_equip_plu_capi AS gis
		WHERE ST_Area(gis.geom) >= 2000
;

create index in_gisement_bati_s on gst_grandmaison_prima.gisement_bati_s using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.par_u_lin_equip_plu_capi;

--- Bâtiment par tènement (gisement)
DROP TABLE IF EXISTS gst_grandmaison_prima.bat_gis_capi;
CREATE TABLE gst_grandmaison_prima.bat_gis_capi AS
	SELECT
		ST_intersection(ST_Union(bat.geom), gis.geom) as geom
	FROM
		gst_grandmaison_prima.gisement_bati_s AS gis
		JOIN geonum_reference.bdtopo_batiment as bat on ST_intersects(gis.geom, bat.geom)
	GROUP BY gis.geom
;

create index in_bat_gis_capi on gst_grandmaison_prima.bat_gis_capi using gist(geom);

--- Calcul du CES (Coefficient d'emprise au sol) par parcelle
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_bati;
CREATE TABLE gst_grandmaison_prima.gisement_bati AS
	SELECT
		gis.geom as geom,
		ST_Area(bat.geom)/gis.surface_t as CES
	FROM
		gst_grandmaison_prima.gisement_bati_s AS gis
		JOIN gst_grandmaison_prima.bat_gis_capi as bat on ST_contains(gis.geom, bat.geom)
	WHERE ST_Area(bat.geom)/gis.surface_t <= 0.2
;

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_bati_s;
DROP TABLE IF EXISTS gst_grandmaison_prima.bat_gis_capi;

--- Créer une colonne type avec le type de gisement
ALTER TABLE gst_grandmaison_prima.gisement_bati
ADD COLUMN typologie CHAR(25) DEFAULT 'bâti';

create index in_gisement_bati on gst_grandmaison_prima.gisement_bati using gist(geom);

--- Union pour retirer du gnb (gisement non-bâti) le gb (gisement bâti)
DROP TABLE IF EXISTS gst_grandmaison_prima.ces_gis_capi;
CREATE TABLE gst_grandmaison_prima.ces_gis_capi AS
	SELECT
		ST_union(gis.geom) as geom
	FROM
		gst_grandmaison_prima.gisement_bati as gis
;

create index in_ces_gis_capi on gst_grandmaison_prima.ces_gis_capi using gist(geom);

DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_nb_u;
CREATE TABLE gst_grandmaison_prima.gisement_nb_u AS
	SELECT
		ST_union(gis.geom) as geom
	FROM
		gst_grandmaison_prima.gisement_nb_capi as gis
;

create index in_gisement_nb_u on gst_grandmaison_prima.gisement_nb_u using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_nb_capi;


----------------------------------------------------------------------------------------------------------
-- Partie 7 : Mise en forme finale
--- Eviter le chevauchement des deux types de gisement
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_nb;
CREATE TABLE gst_grandmaison_prima.gisement_nb AS
SELECT
	(ST_Dump(ST_Difference(gisnb.geom, gisb.geom))).geom AS geom
	FROM 
		gst_grandmaison_prima.gisement_nb_u AS gisnb,
		gst_grandmaison_prima.ces_gis_capi AS gisb
	WHERE ST_Intersects(gisnb.geom, gisb.geom)
;

--- Créer une colonne type avec le type de gisement pour le non-bâti
ALTER TABLE gst_grandmaison_prima.gisement_nb
ADD COLUMN typologie CHAR(25) DEFAULT 'non-bâti';

create index in_gisement_nb on gst_grandmaison_prima.gisement_nb using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_nb_u;
DROP TABLE IF EXISTS gst_grandmaison_prima.ces_gis_capi;

--- Fusion des couches de gisement
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_fusion;
CREATE TABLE gst_grandmaison_prima.gisement_fusion AS	
	SELECT bat.geom, bat.typologie
		FROM gst_grandmaison_prima.gisement_bati as bat
	UNION
	SELECT nb.geom, nb.typologie
		FROM gst_grandmaison_prima.gisement_nb as nb
;

create index in_gisement_fusion on gst_grandmaison_prima.gisement_fusion using gist(geom);

--- suppression de couches
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_bati;
DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_nb;

--- Renommer les colonnes et filtrer pour ne conserver que les plus de 2 000 m²
DROP TABLE IF EXISTS gst_grandmaison_prima.gst_bati_nonbati;
CREATE TABLE gst_grandmaison_prima.gst_bati_nonbati AS
	SELECT
	gis.geom,
	gis.typologie as nature,
	ST_Area(gis.geom) as surface
	FROM
		gst_grandmaison_prima.gisement_fusion AS gis
	WHERE ST_Area(gis.geom) >= 2000
;

--- Créer un identifiant unique à chaque tènement
ALTER TABLE gst_grandmaison_prima.gst_bati_nonbati
ADD COLUMN idgst SERIAL PRIMARY KEY;

create index in_gst_bati_nonbati on gst_grandmaison_prima.gst_bati_nonbati using gist(geom);


DROP TABLE IF EXISTS gst_grandmaison_prima.gisement_fusion;


----------------------------------------------------------------------------------------------------------
--- Ce qui aurait-été utile de faire, mais que nous n'avons pas eu le temps ---

-- Le calcul des gisement ne prend pas en compte la forme de la géométrie. En effet, certains gisements ou partie de gisements ne font que quelques mètres de largeur...
-- Ce n'est donc pas un potentiel constructible.
-- La solution est d'utiliser l'indice de compacité/circularité dont la formule est la suivante :
--	2pi((racine(surface)/pi)/périmètre)
-- Avant d'appliquer cette formule il faut redécouper les gisements afin de séparer les artéfacts, la solution proposée est st_subdivide.
-- Cette fonction permet de découper des polygone en limitant le nombre de vertices (nombre de sommets).
-- Plus la valeur tend vers 0, moins la forme est compacte.
-- Il faut donc déterminer une valeur seuil pour retirer les formes les moins compactes.

-- Limites : 
-- La subdivision pose problème car certains artéfacts (les courbes fines par exemple) sont conservés, tandis que certaines bordures des polygones serait retirées.

-- Nous avons effectué des tests, et n'avons pas pu trouver de solution satisfaisante pour les mettres dans le script final.