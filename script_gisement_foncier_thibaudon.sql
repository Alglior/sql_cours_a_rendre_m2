--------------------------------------------------------------------------------
-- TITRE : ANALYSE DU POTENTIEL FONCIER (GISEMENT) - TERRITOIRE CAPI
-- AUTEUR : Arthur THIBAUDON ; Paul VALENTIN M2 GEO-NUM
-- OBJECTIF : Identifier les surfaces non bâties sur les parcelles privées
--            en excluant les bâtiments, les routes et les équipements publics.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- PHASE D'INITIALISATION
--------------------------------------------------------------------------------
-- Création du schéma pour éviter de travailler dans le schéma geonum_reference
-- Cela permet d'isoler nos tables de travail et de ne pas polluer le schéma de référence.
-- C'est une "bonne pratique" essentielle : on ne touche jamais aux données sources.
--- On utilise CASCADE pour supprimer toutes les tables dépendantes si le schéma existe déjà.
DROP SCHEMA IF EXISTS gst_arthur CASCADE;
CREATE SCHEMA gst_arthur;

--------------------------------------------------------------------------------
-- ETAPE 0 : DÉFINITION DE LA ZONE D'ÉTUDE (AOI - Area of Interest)
--------------------------------------------------------------------------------
-- Détermination de l’emprise du territoire d’identification du gisement
-- Selection de l'EPCI CA Porte de l'Isère (CAPI) avec son code epci.
-- Note : Le code EPCI est une chaîne de caractères, d'où l'usage des guillemets simples.
DROP TABLE IF EXISTS gst_arthur.communes_epci_capi;
CREATE TABLE gst_arthur.communes_epci_capi AS

SELECT * FROM geonum_reference.commune
WHERE epci LIKE '243800604';
-- On crée ici une "table de filtrage" qui servira à limiter toutes les requêtes spatiales suivantes.

--------------------------------------------------------------------------------
-- ETAPE 1 : CONTRAINTES LIÉES AU BÂTI EXISTANT
--------------------------------------------------------------------------------
-- Création du masque bâtiment : On définit les zones "interdites" autour des bâtiments.
-- Adaptation du masque selon la taille du bati (2m <50m² sinon 50m).
-- LOGIQUE MÉTIER :
-- 1. Petits bâtiments (<50m²) : Souvent des annexes ou garages. On garde juste une marge technique (2m).
-- 2. Gros bâtiments (>=50m²) : Bâtiments principaux. On applique une règle d'urbanisme stricte (recul de 50m).
DROP TABLE IF EXISTS gst_arthur.masque_batiment;
CREATE TABLE gst_arthur.masque_batiment AS

SELECT (ST_Dump(ST_Union(
    ST_Intersection(
        ST_Buffer(
            bat.geom,
            CASE
                WHEN ST_Area(bat.geom) < 50 THEN 2
                ELSE 50
            END
        ),
        com.geom -- intersect avec commune geometry
    )
))).geom::geometry(Polygon, 2154) AS geom
FROM geonum_reference.bdtopo_batiment AS bat
JOIN gst_arthur.communes_epci_capi AS com
  ON ST_Intersects(bat.geom, com.geom);

--------------------------------------------------------------------------------
-- ETAPE 2 : CONTRAINTES LIÉES AUX INFRASTRUCTURES LINÉAIRES
--------------------------------------------------------------------------------
-- Création du masque des infrastructures linéaires (route, rail).
-- Voirie principale/Rail : 15m de recul.
-- Voirie secondaire : 7m de recul.
-- Supprime la table 'masque_infra' si elle existe afin de pouvoir recréer la table proprement
DROP TABLE IF EXISTS gst_arthur.masque_infra;

-- Création de la nouvelle table 'masque_infra' dans l'espace de noms 'gst_arthur'
CREATE TABLE gst_arthur.masque_infra AS

-- Définition d'une zone d'étude unique appelée 'zone_etude' en utilisant une CTE (WITH)
WITH zone_etude AS (
    -- Fusionne toutes les géométries des communes constituant la CAPI en une géométrie unique
    SELECT ST_Union(geom) AS geom
    FROM gst_arthur.communes_epci_capi
)

-- Construction finale de la géométrie résultat
SELECT
    -- Calcul de l'intersection spatiale entre :
    -- 1) L'union de tous les tampons (buffer) générés autour des routes et rails
    -- 2) La zone d'étude (CAPI) pour limiter le masque aux limites géographiques exactes
    (ST_Dump(ST_Intersection(
        ST_Union(sub.geom),        -- Fusionne toutes les géométries tamponnées entre routes et rails
        (SELECT geom FROM zone_etude) -- Géométrie unique de la CAPI pour découpage final
    ))).geom::geometry(Polygon, 2154) AS geom
FROM (
    -- Bloc A : Calcul des tampons pour les routes
    SELECT
        ST_Buffer(
            r.geom,                 -- La géométrie de la route en question
            CASE                    -- Largeur dynamique du tampon en fonction du type de route (colonne highway)
                -- Pour les routes principales et autoroutes, le tampon est de 15 mètres
                WHEN highway IN ('motorway', 'motorway_link', 'primary', 'primary_link', 'trunk', 'trunk_link') THEN 15
                -- Pour les routes secondaires, le tampon est plus étroit : 7 mètres
                ELSE 7
            END
        ) AS geom
    FROM geonum_reference.osm_road AS r
    -- Jointure spatiale pour ne garder que les routes intersectant la zone d'étude
    JOIN zone_etude z ON ST_Intersects(r.geom, z.geom)

    --Jointure des deux blocs avec UNION ALL pour combiner les résultats
    UNION ALL

    -- Bloc B : Calcul des tampons pour les voies ferrées
    SELECT
        ST_Buffer(rl.geom, 15) AS geom -- Tampon fixe de 15 mètres pour les rails
    FROM geonum_reference.osm_railway rl
    -- Jointure spatiale pour ne garder que les rails intersectant la zone d'étude
    JOIN zone_etude z ON ST_Intersects(rl.geom, z.geom)
) AS sub;

--------------------------------------------------------------------------------
-- ETAPE 3 : CONTRAINTES D'USAGE ET ÉQUIPEMENTS PUBLICS
--------------------------------------------------------------------------------
-- Création du masque des équipements et des spécificités du territoire.
-- On récupère les zones qui ne sont PAS des parcelles privées constructibles
-- (cimetières, stades, parcs, aérodromes, zones industrielles, écoles existantes).
DROP TABLE IF EXISTS gst_arthur.masque_equipement;
CREATE TABLE gst_arthur.masque_equipement AS

SELECT (ST_Dump(ST_Union(geom))).geom::geometry(Polygon, 2154) AS geom FROM (
    --1. Zones d'activités
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.bdtopo_zone_d_activite_ou_d_interet
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_arthur.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <--- ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --2. Aérodromes
    SELECT ST_Force2D(ST_Buffer(geom,100))::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.bdtopo_aerodrome
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_arthur.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <---  ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --3. Cimetières
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.bdtopo_cimetiere
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_arthur.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <---  ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --4. Centres sportifs (Surface seulement)
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.osm_sport_center
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_arthur.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <---  ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --5. Parcs
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.osm_park
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_arthur.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <--- ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --6. Eau
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.osm_water
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_arthur.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <---  ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    -- 7. Ecoles (OSM) avec buffer 50m
    SELECT ST_Buffer(ST_Force2D(geom), 50)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.osm_school
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_arthur.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <--- ne prend pas les points

    UNION ALL
    -- 8. Poste de transformation électrique (OSM) avec buffer 50m
    SELECT ST_Buffer(ST_Force2D(geom), 50)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.osm_school
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_arthur.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <--- ne prend pas les points
) equipements;

--------------------------------------------------------------------------------
-- ETAPE 4 : SÉLECTION DU FONCIER BRUT (PARCELLES)
--------------------------------------------------------------------------------
-- Identification des parcelles candidates grâce au zonage d'urbanisme en vigueur.
-- On ne garde que les parcelles cadastrales qui touchent sont dans notre territoire.
-- On ajoute aux données d'urbanisme la tâche urbaine pour pallier au problème que
-- certaines communes n'ont pas de données (Eclose-Badinieres et Vaulx-Milieu)

DROP TABLE IF EXISTS gst_arthur.parcelles_candidates;

CREATE TABLE gst_arthur.parcelles_candidates AS

SELECT zu.*
FROM geonum_reference.zonage_urbanisme AS zu
JOIN gst_arthur.communes_epci_capi AS c
ON ST_Intersects(zu.geom, c.geom)
WHERE typezone IN('U', 'AUc', 'AUs'); -- Condition de jointure spatiale basique

--------------------------------------------------------------------------------
-- ETAPE 5 : IDENTIFICATION DU GISEMENT NON BATI
--------------------------------------------------------------------------------
-- On retire des parcelles candidates toutes les zones bâties, présentant des infrastructures ou équipements
-- On observe le résultat non nettoyé
-- on utilise st_difference

DROP TABLE IF EXISTS gst_arthur.masque_total; -- Création d'une table contenant tous les masques
CREATE TABLE gst_arthur.masque_total AS

SELECT ST_Union(geom) AS geom -- Fusion de l'ensemble des géométries de masque
FROM (
    SELECT geom
    FROM gst_arthur.masque_batiment
    UNION ALL
    SELECT geom
    FROM gst_arthur.masque_infra
	UNION ALL
	SELECT geom
	FROM gst_arthur.masque_equipement
) AS s;

DROP TABLE IF EXISTS gst_arthur.gnb_brut;
CREATE TABLE gst_arthur.gnb_brut AS

SELECT 
    p.gid, p.libelle, p.typezone,  -- sauvegarde des colonnes utiles
    (ST_Dump(ST_Difference(p.geom, m.geom))).geom::geometry(Polygon, 2154) AS geom,
    -- extraction  des géométries dans la surface bati non concernées par un masque. On convertit les polygones multi-parties en plusieurs polygones
    ST_Area((ST_Dump(ST_Difference(p.geom, m.geom))).geom) AS area_m2 -- calcul de l'area sur ce qui est explicité ci dessus
FROM gst_arthur.parcelles_candidates AS p
CROSS JOIN gst_arthur.masque_total AS m
WHERE ST_Intersects(p.geom, m.geom)
  AND NOT ST_IsEmpty(ST_Difference(p.geom, m.geom));


--------------------------------------------------------------------------------
-- ETAPE 6 : CRÉATION DE LA TACHE URBAINE (Méthode du SCOT)
--------------------------------------------------------------------------------
-- Identification de l'enveloppe urbaine selon la méthode du SCOT :
-- 1. Premier buffer de +50m autour des masques combinés (bâti + infra + équipements)
-- 2. Deuxième buffer de -30m pour créer une zone de transition urbaine
-- La tache urbaine représente l'espace de consommation foncière existante et sa continuité
-- Découpage par commune pour une analyse territorialisée

-- 1. On crée d'abord le buffer sur le masque global (une seule fois)
DROP TABLE IF EXISTS gst_arthur.temp_buffer_global;
CREATE TABLE gst_arthur.temp_buffer_global AS 
SELECT ST_Buffer(ST_Buffer(geom, 50), -30) as geom
FROM gst_arthur.masque_total;

-- 2. On indexe cette géométrie temporaire
CREATE INDEX idx_temp_buffer_geom ON gst_arthur.temp_buffer_global USING GIST(geom);

-- 3. On fait l'intersection par commune (beaucoup plus rapide)
DROP TABLE IF EXISTS gst_arthur.tache_urbaine;
CREATE TABLE gst_arthur.tache_urbaine AS
SELECT 
    c.codgeo,
    c.libgeo,
    (ST_Dump(ST_Intersection(b.geom, c.geom))).geom::geometry(Polygon, 2154) AS geom
FROM gst_arthur.temp_buffer_global b
JOIN gst_arthur.communes_epci_capi AS c ON ST_Intersects(b.geom, c.geom);

-- 4. On ajoute les surfaces à la fin (mieux vaut le faire sur les polygones déjà découpés)
ALTER TABLE gst_arthur.tache_urbaine ADD COLUMN area_m2 float;
UPDATE gst_arthur.tache_urbaine SET area_m2 = ST_Area(geom);

--------------------------------------------------------------------------------
-- ETAPE 7 : MISE EN FORME DE LA COUCHE FINALE
----------------------------------------------------------------------------------
-- On ne fait apparaître que les éléments ayant plus de 2000m² de terrain potentiellement constructibles

DROP TABLE IF EXISTS gst_arthur.gnb_final;
CREATE TABLE gst_arthur.gnb_final AS

SELECT *
FROM gst_arthur.gnb_brut
WHERE area_m2 >= 2000 -- Filtre du gisement bati en ne récupérant que les surfaces supérieures à 2000 m²
ORDER BY area_m2 DESC
