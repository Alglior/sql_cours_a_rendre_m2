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
DROP SCHEMA IF EXISTS arthur_td CASCADE;
CREATE SCHEMA arthur_td;

--------------------------------------------------------------------------------
-- ETAPE 0 : DÉFINITION DE LA ZONE D'ÉTUDE (AOI - Area of Interest)
--------------------------------------------------------------------------------
-- Détermination de l’emprise du territoire d’identification du gisement
-- Selection de l'EPCI CA Porte de l'Isère (CAPI) avec son code epci.
-- Note : Le code EPCI est une chaîne de caractères, d'où l'usage des guillemets simples.
DROP TABLE IF EXISTS arthur_td.communes_epci_capi;
CREATE TABLE arthur_td.communes_epci_capi AS

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
DROP TABLE IF EXISTS arthur_td.masque_batiment;
CREATE TABLE arthur_td.masque_batiment AS

SELECT ST_Union(
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
) AS geom
FROM geonum_reference.bdtopo_batiment AS bat
JOIN arthur_td.communes_epci_capi AS com
  ON ST_Intersects(bat.geom, com.geom);

-- L'utilisation de ST_Union est CRUCIALE ici : elle fusionne tous les tampons (buffers) qui se chevauchent
-- en une seule géométrie géante (MultiPolygon). Cela évite de compter plusieurs fois la même surface.

--------------------------------------------------------------------------------
-- ETAPE 2 : CONTRAINTES LIÉES AUX INFRASTRUCTURES LINÉAIRES
--------------------------------------------------------------------------------
-- Création du masque des infrastructures linéaires (route, rail).
-- Voirie principale/Rail : 15m de recul.
-- Voirie secondaire : 7m de recul.
-- Supprime la table 'masque_infra' si elle existe afin de pouvoir recréer la table proprement
DROP TABLE IF EXISTS arthur_td.masque_infra;

-- Création de la nouvelle table 'masque_infra' dans l'espace de noms 'arthur_td'
CREATE TABLE arthur_td.masque_infra AS

-- Définition d'une zone d'étude unique appelée 'zone_etude' en utilisant une CTE (WITH)
WITH zone_etude AS (
    -- Fusionne toutes les géométries des communes constituant la CAPI en une géométrie unique
    SELECT ST_Union(geom) AS geom
    FROM arthur_td.communes_epci_capi
)

-- Construction finale de la géométrie résultat
SELECT
    -- Calcul de l'intersection spatiale entre :
    -- 1) L'union de tous les tampons (buffer) générés autour des routes et rails
    -- 2) La zone d'étude (CAPI) pour limiter le masque aux limites géographiques exactes
    ST_Intersection(
        ST_Union(sub.geom),        -- Fusionne toutes les géométries tamponnées entre routes et rails
        (SELECT geom FROM zone_etude) -- Géométrie unique de la CAPI pour découpage final
    ) AS geom
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
    FROM geonum_reference.osm_road r
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
DROP TABLE IF EXISTS arthur_td.masque_equipement;
CREATE TABLE arthur_td.masque_equipement AS

SELECT ST_Union(geom) AS geom FROM (
    --1. Zones d'activités
    SELECT ST_Force2D(ST_Multi(geom))::geometry(MultiPolygon, 2154) AS geom
    FROM geonum_reference.bdtopo_zone_d_activite_ou_d_interet
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM arthur_td.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <--- ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --2. Aérodromes
    SELECT ST_Force2D(ST_Buffer(ST_Multi(geom),100))::geometry(MultiPolygon, 2154) AS geom
    FROM geonum_reference.bdtopo_aerodrome
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM arthur_td.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <---  ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --3. Cimetières
    SELECT ST_Force2D(ST_Multi(geom))::geometry(MultiPolygon, 2154) AS geom
    FROM geonum_reference.bdtopo_cimetiere
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM arthur_td.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <---  ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --4. Centres sportifs (Surface seulement)
    SELECT ST_Force2D(ST_Multi(geom))::geometry(MultiPolygon, 2154) AS geom
    FROM geonum_reference.osm_sport_center
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM arthur_td.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <---  ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --5. Parcs
    SELECT ST_Force2D(ST_Multi(geom))::geometry(MultiPolygon, 2154) AS geom
    FROM geonum_reference.osm_park
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM arthur_td.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <--- ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    --6. Eau
    SELECT ST_Force2D(ST_Multi(geom))::geometry(MultiPolygon, 2154) AS geom
    FROM geonum_reference.osm_water
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM arthur_td.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <---  ne prend pas les points s'il y a des zones ponctuelles

    UNION ALL
    -- 7. Ecoles (OSM) avec buffer 50m
    SELECT ST_Multi(ST_Buffer(ST_Force2D(geom), 50))::geometry(MultiPolygon, 2154) AS geom
    FROM geonum_reference.osm_school
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM arthur_td.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <--- ne prend pas les points

    UNION ALL
    -- 8. Poste de transformation électrique (OSM) avec buffer 50m
    SELECT ST_Multi(ST_Buffer(ST_Force2D(geom), 50))::geometry(MultiPolygon, 2154) AS geom
    FROM geonum_reference.osm_school
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM arthur_td.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- <--- ne prend pas les points
) equipements;


-- Note Technique : ST_Force2D et ST_Multi assurent que toutes les géométries
-- ont le même format pour pouvoir être fusionnées (pas de mélange 2D/3D ou Polygon/MultiPolygon).

--------------------------------------------------------------------------------
-- ETAPE 4 : SÉLECTION DU FONCIER BRUT (PARCELLES)
--------------------------------------------------------------------------------
-- Identification des parcelles candidates.
-- On ne garde que les parcelles cadastrales qui touchent sont dans notre territoire.
DROP TABLE IF EXISTS arthur_td.parcelles_candidates;

CREATE TABLE arthur_td.parcelles_candidates AS

SELECT DISTINCT p.*  -- DISTINCT pour éviter les doublons si une parcelle intersecte plusieurs communes
FROM geonum_reference.parcelles AS p
JOIN arthur_td.communes_epci_capi AS c
ON ST_Intersects(p.geom, c.geom);  -- Condition de jointure spatiale basique
