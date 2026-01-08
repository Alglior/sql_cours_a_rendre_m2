\set ON_ERROR_STOP on
SET client_encoding = 'UTF8';
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
DROP SCHEMA IF EXISTS gst_thibaudon_valentin CASCADE;
CREATE SCHEMA gst_thibaudon_valentin;

--------------------------------------------------------------------------------
-- ETAPE 0 : DÉFINITION DE LA ZONE D'ÉTUDE (AOI - Area of Interest)
--------------------------------------------------------------------------------
-- Détermination de l’emprise du territoire d’identification du gisement
-- Selection de l'EPCI CA Porte de l'Isère (CAPI) avec son code epci.
-- Note : Le code EPCI est une chaîne de caractères, d'où l'usage des guillemets simples.
-- CONTEXTE : L'EPCI (Établissement Public de Coopération Intercommunale) est l'échelon territorial
-- pertinent pour cette analyse. Le code '243800604' identifie la CAPI de manière unique.
-- Cette sélection permet de circonscrire géographiquement toute l'analyse qui suit.
DROP TABLE IF EXISTS gst_thibaudon_valentin.communes_epci_capi;
CREATE TABLE gst_thibaudon_valentin.communes_epci_capi AS

SELECT * FROM geonum_reference.commune
WHERE epci LIKE '243800604';
-- On crée ici une "table de filtrage" qui servira à limiter toutes les requêtes spatiales suivantes.
-- Cette table de référence évitera de répéter la clause WHERE dans chaque requête ultérieure,
-- améliorant ainsi les performances et la maintenabilité du script.

--------------------------------------------------------------------------------
-- ETAPE 1 : CONTRAINTES LIÉES AU BÂTI EXISTANT
--------------------------------------------------------------------------------
-- Création du masque bâtiment : On définit les zones "interdites" autour des bâtiments.
-- Adaptation du masque selon la taille du bati (2m <50m² sinon 50m).
-- LOGIQUE MÉTIER :
-- 1. Petits bâtiments (<50m²) : Souvent des annexes ou garages. On garde juste une marge technique (2m).
--     Ces petites structures ne constituent pas nécessairement un obstacle à la constructibilité future.
--     Le buffer de 2m correspond à une marge de sécurité pour les opérations techniques (accès, entretien).
-- 2. Gros bâtiments (>=50m²) : Bâtiments principaux. On applique une règle d'urbanisme stricte (recul de 50m).
--     Ces bâtiments sont des constructions principales qui génèrent des contraintes urbanistiques importantes.
--     Le recul de 50m respecte les distances minimales imposées par les règlements d'urbanisme
--       (vues, ensoleillement, intimité, risques d'incendie).
DROP TABLE IF EXISTS gst_thibaudon_valentin.masque_batiment;
CREATE TABLE gst_thibaudon_valentin.masque_batiment AS

SELECT (ST_Dump(ST_Union(
    ST_Intersection(
        ST_Buffer(
            bat.geom,
            CASE
                WHEN ST_Area(bat.geom) < 50 THEN 2
                ELSE 50
            END
        ),
        com.geom -- Intersection avec la géométrie de la commune pour limiter le buffer aux frontières administratives
                 -- Cela évite de créer des masques qui déborderaient hors de notre zone d'étude (CAPI)
    )
))).geom::geometry(Polygon, 2154) AS geom
FROM geonum_reference.bdtopo_batiment AS bat
JOIN gst_thibaudon_valentin.communes_epci_capi AS com
  ON ST_Intersects(bat.geom, com.geom);

--------------------------------------------------------------------------------
-- ETAPE 2 : CONTRAINTES LIÉES AUX INFRASTRUCTURES LINÉAIRES
--------------------------------------------------------------------------------
-- Création du masque des infrastructures linéaires (route, rail).
-- CONTEXTE : Les infrastructures de transport génèrent des nuisances (bruit, pollution, danger)
-- et sont soumises à des servitudes d'urbanisme qui limitent la constructibilité à proximité.
-- Voirie principale/Rail : 15m de recul.
--     Distances correspondant aux servitudes légales le long des axes structurants
--     Protection contre les nuisances sonores et la pollution atmosphérique
-- Voirie secondaire : 7m de recul.
--     Recul réduit car nuisances moindres et besoins d'accès aux parcelles riveraines
-- Supprime la table 'masque_infra' si elle existe afin de pouvoir recréer la table proprement
DROP TABLE IF EXISTS gst_thibaudon_valentin.masque_infra;

-- Création de la nouvelle table 'masque_infra' dans l'espace de noms 'gst_thibaudon_valentin'
CREATE TABLE gst_thibaudon_valentin.masque_infra AS

-- Définition d'une zone d'étude unique appelée 'zone_etude' en utilisant une CTE (WITH)
WITH zone_etude AS (
    -- Fusionne toutes les géométries des communes constituant la CAPI en une géométrie unique
    SELECT ST_Union(geom) AS geom
    FROM gst_thibaudon_valentin.communes_epci_capi
)

-- Construction finale de la géométrie résultat
SELECT
    -- Calcul de l'intersection spatiale entre :
    -- 1) L'union de tous les tampons (buffer) générés autour des routes et rails
    --     ST_Union permet de fusionner tous les buffers en une seule géométrie continue,
    --       évitant les doublons et les chevauchements entre infrastructures proches
    -- 2) La zone d'étude (CAPI) pour limiter le masque aux limites géographiques exactes
    --     L'intersection garantit qu'aucune zone de contrainte ne soit calculée hors territoire
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
                --  Catégories OSM : motorway (autoroute), trunk (voie express), primary (route principale)
                --  Les suffixes '_link' désignent les bretelles de raccordement à ces axes
                WHEN highway IN ('motorway', 'motorway_link', 'primary', 'primary_link', 'trunk', 'trunk_link') THEN 15
                -- Pour les routes secondaires, le tampon est plus étroit : 7 mètres
                --  Toutes les autres catégories de voies (secondary, tertiary, residential, etc.)
                --  Impact moindre sur la constructibilité car trafic et nuisances réduits
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
                                       --  Distance minimale pour les servitudes ferroviaires

    FROM geonum_reference.osm_railway rl
    -- Jointure spatiale pour ne garder que les rails intersectant la zone d'étude
    JOIN zone_etude z ON ST_Intersects(rl.geom, z.geom)
) AS sub;

--------------------------------------------------------------------------------
-- ETAPE 3 : CONTRAINTES D'USAGE ET ÉQUIPEMENTS PUBLICS
--------------------------------------------------------------------------------
-- Création du masque des équipements et des spécificités du territoire.
-- CONTEXTE : Certaines zones, bien que non bâties, ne constituent pas du foncier mobilisable
-- car elles sont affectées à des usages d'intérêt général ou soumises à des contraintes spécifiques.
-- On récupère les zones qui ne sont PAS des parcelles privées constructibles :
--  Équipements publics (cimetières, écoles, aérodromes) : domaine public non aliénable
--  Espaces de loisirs (stades, parcs) : fonction sociale et écologique à préserver
--  Zones d'activités économiques : déjà affectées à un usage productif
--  Cours d'eau : contraintes environnementales et risques d'inondation
DROP TABLE IF EXISTS gst_thibaudon_valentin.masque_equipement;
CREATE TABLE gst_thibaudon_valentin.masque_equipement AS

SELECT (ST_Dump(ST_Union(geom))).geom::geometry(Polygon, 2154) AS geom FROM (
    --1. Zones d'activités
    --  Zones industrielles, commerciales et artisanales déjà affectées à l'économie productive
    --  Ces espaces ne sont pas disponibles pour du foncier résidentiel ou mixte
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.bdtopo_zone_d_activite_ou_d_interet
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_thibaudon_valentin.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- Filtre les géométries de dimension 2 (polygones/surfaces uniquement)
                                   --  Exclut les points (dimension 0) et les lignes (dimension 1) qui n'ont pas de surface
                                   --  Garantit qu'on ne crée pas de masque à partir d'une simple coordonnée ponctuelle

    UNION ALL
    --2. Aérodromes
    --  Zone soumise à des servitudes aéronautiques strictes (servitudes T, bruit, dégagement)
    --  Buffer de 100m pour intégrer les contraintes de bruit et de sécurité au-delà de l'emprise
    SELECT ST_Force2D(ST_Buffer(geom,100))::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.bdtopo_aerodrome
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_thibaudon_valentin.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- Filtre pour ne conserver que les surfaces (polygones)
                                   --  Évite de créer un buffer circulaire de 100m autour d'un simple point

    UNION ALL
    --3. Cimetières
    --  Domaine public communal affecté au service public funéraire
    --  Non aliénable et soumis à des réglementations sanitaires spécifiques
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.bdtopo_cimetiere
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_thibaudon_valentin.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- Ne retient que les emprises surfaciques des cimetières
                                   --  Les points de données seraient des localisations approximatives sans emprise réelle

    UNION ALL
    --4. Centres sportifs (Surface seulement)
    --  Équipements publics dédiés aux activités sportives et de loisirs
    --  Fonction sociale importante : maintien de la santé publique et du lien social
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.osm_sport_center
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_thibaudon_valentin.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- Ne conserve que les surfaces (stades, terrains, complexes sportifs)
                                   --  Exclut les points OSM qui pourraient représenter de petits équipements ponctuels

    UNION ALL
    --5. Parcs
    --  Espaces verts urbains assurant des fonctions écologiques (îlots de fraîcheur, biodiversité)
    --  Rôle social (loisirs, détente) et contribution au cadre de vie
    --  Éléments de la trame verte urbaine à préserver dans les documents d'urbanisme
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.osm_park
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_thibaudon_valentin.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- Ne retient que les emprises surfaciques des parcs
                                   --  Évite de masquer une zone entière à partir d'un point d'entrée du parc

    UNION ALL
    --6. Eau
    --  Plans d'eau, lacs, étangs, zones humides : milieux naturels protégés (SDAGE, Loi sur l'eau)
    --  Risques d'inondation et servitudes d'écoulement des eaux
    --  Préservation de la ressource en eau et des écosystèmes aquatiques
    SELECT ST_Force2D(geom)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.osm_water
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_thibaudon_valentin.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- Sélection des surfaces en eau uniquement
                                   --  Les points pourraient être des sources, fontaines, sans emprise surfacique significative

    UNION ALL
    -- 7. Écoles (OSM) avec buffer 50m
    --  Équipements publics d'enseignement (maternelles, primaires, collèges, lycées)
    --  Buffer de 50m pour préserver un environnement calme et sécurisé autour des établissements
    --  Zone tampon contre les nuisances et pour la sécurité des enfants (circulation, bruit)
    SELECT ST_Buffer(ST_Force2D(geom), 50)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.osm_school
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_thibaudon_valentin.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- Ne prend que les emprises des établissements scolaires (surfaces)
                                   --  Les points seraient des localisations approximatives sans emprise définie

    UNION ALL
    -- 8. Postes de transformation électrique (OSM) avec buffer 50m
    --  Infrastructures du réseau électrique haute et moyenne tension
    --  Buffer de 50m pour les servitudes liées aux champs électromagnétiques
    --  Distance de sécurité réglementaire par rapport aux installations électriques
    SELECT ST_Buffer(ST_Force2D(geom), 50)::geometry(Geometry, 2154) AS geom
    FROM geonum_reference.bdtopo_poste_de_transformation
    WHERE ST_Intersects(geom, (SELECT ST_Union(geom) FROM gst_thibaudon_valentin.communes_epci_capi))
        AND ST_Dimension(geom) = 2 -- Filtre pour ne traiter que les emprises surfaciques
                                   --  Les postes de transformation peuvent être cartographiés en points ou polygones
) equipements;

--------------------------------------------------------------------------------
-- ETAPE 4 : SÉLECTION DU FONCIER BRUT (PARCELLES)
--------------------------------------------------------------------------------
-- Identification des parcelles candidates grâce au zonage d'urbanisme en vigueur.
-- CONTEXTE : Le Plan Local d'Urbanisme (PLU) classe le territoire en zones ayant des vocations différentes.
-- On ne garde que les parcelles cadastrales qui sont dans notre territoire.
-- LOGIQUE DE SÉLECTION :
--  Zone U (Urbaine) : zone déjà urbanisée où les constructions sont autorisées
--  Zone AUc (À Urbaniser constructible) : zone d'extension urbaine programmée à court terme
--  Zone AUs (À Urbaniser stricte) : zone d'urbanisation future conditionnée à une évolution du PLU
-- Les zones A (Agricole) et N (Naturelle) sont exclues car protégées de l'urbanisation.
-- NOTE : On utilise le zonage d'urbanisme plutôt que le parcellaire cadastral car certaines communes
-- (Éclose-Badinières et Vaulx-Milieu) présentent des lacunes dans les données cadastrales.

DROP TABLE IF EXISTS gst_thibaudon_valentin.parcelles_candidates;

CREATE TABLE gst_thibaudon_valentin.parcelles_candidates AS

SELECT zu.*
FROM geonum_reference.zonage_urbanisme AS zu
JOIN gst_thibaudon_valentin.communes_epci_capi AS c
ON ST_Intersects(zu.geom, c.geom)
WHERE typezone IN('U', 'AUc', 'AUs'); -- Sélection des zones constructibles selon le PLU
                                      --  U : zone urbaine dense, équipements existants
                                      --  AUc : ouverture à l'urbanisation immédiate possible
                                      --  AUs : urbanisation future, nécessite modification du PLU

--------------------------------------------------------------------------------
-- ETAPE 5 : IDENTIFICATION DU GISEMENT NON BATI
--------------------------------------------------------------------------------
-- On retire des parcelles candidates toutes les zones bâties, présentant des infrastructures ou équipements
-- PRINCIPE : Le gisement foncier = surfaces constructibles MOINS les contraintes identifiées
-- MÉTHODE : Utilisation de ST_Difference (différence booléenne) pour soustraire les masques
-- Cette étape produit le "gisement brut" qui sera ensuite affiné et qualifié

DROP TABLE IF EXISTS gst_thibaudon_valentin.masque_total; 
CREATE TABLE gst_thibaudon_valentin.masque_total AS

-- Création d'une table contenant la fusion de TOUS les masques de contraintes
--  Cette approche optimise les performances : une seule opération ST_Difference au lieu de trois successives
--  ST_Union dissout les frontières internes entre masques pour créer une géométrie unique
SELECT ST_Union(geom) AS geom
FROM (
    SELECT geom

    FROM gst_thibaudon_valentin.masque_batiment

    UNION ALL

    SELECT geom

    FROM gst_thibaudon_valentin.masque_infra

	UNION ALL

	SELECT geom

	FROM gst_thibaudon_valentin.masque_equipement
) AS s;

DROP TABLE IF EXISTS gst_thibaudon_valentin.gnb_brut;
CREATE TABLE gst_thibaudon_valentin.gnb_brut AS

SELECT 
    p.gid, p.libelle, p.typezone,  -- Sauvegarde des attributs descriptifs des zones d'urbanisme
    (ST_Dump(ST_Difference(p.geom, m.geom))).geom::geometry(Polygon, 2154) AS geom,
    -- ST_Difference : soustraction spatiale (parcelle MOINS masque)
    -- ST_Dump : éclate les MultiPolygon en Polygon simples pour faciliter les analyses ultérieures
    --  Chaque fragment de gisement devient une entité géographique indépendante
    ST_Area((ST_Dump(ST_Difference(p.geom, m.geom))).geom) AS area_m2 -- Calcul immédiat de la surface en m²
                                                                       --  Permet le tri et le filtrage par taille de gisement
FROM gst_thibaudon_valentin.parcelles_candidates AS p
CROSS JOIN gst_thibaudon_valentin.masque_total AS m  -- CROSS JOIN car le masque est une géométrie unique
                                                      --  Pas besoin de condition de jointure attributaire
WHERE ST_Intersects(p.geom, m.geom)                   -- Filtre spatial : seules les parcelles concernées par un masque
                                                      --  Optimisation : évite de calculer des différences nulles
  AND NOT ST_IsEmpty(ST_Difference(p.geom, m.geom)); -- Exclut les parcelles entièrement recouvertes par les masques
                                                      --  Pas de gisement si la parcelle est totalement contrainte


--------------------------------------------------------------------------------
-- ETAPE 6 : CRÉATION DE LA TACHE URBAINE (Méthode du SCOT)
--------------------------------------------------------------------------------
-- Identification de l'enveloppe urbaine selon la méthode du SCOT (Schéma de Cohérence Territoriale) :
-- OBJECTIF : Délimiter l'enveloppe de l'urbanisation continue pour mesurer l'étalement urbain
-- MÉTHODE :
-- 1. Premier buffer de +50m autour des masques combinés (bâti + infra + équipements)
--     Extension virtuelle pour combler les petits espaces interstitiels
--     Permet de relier les îlots urbains séparés par de petites coupures (jardins, venelles)
-- 2. Deuxième buffer de -30m pour créer une zone de transition urbaine
--     Retrait pour revenir à une enveloppe plus proche de la réalité physique
--     Buffer net de 20m (50m - 30m) pour lisser les contours tout en capturant la continuité
-- RÉSULTAT : La tache urbaine représente l'espace de consommation foncière existante et sa continuité
-- Elle permet de distinguer l'urbanisation dense des hameaux isolés et du mitage rural
-- Découpage par commune pour une analyse territorialisée et des indicateurs locaux

-- 1. On crée d'abord le buffer sur le masque global (une seule fois)
-- OPTIMISATION : Calcul du double buffer en une seule passe sur la géométrie unifiée
--  Beaucoup plus performant que de le faire commune par commune
DROP TABLE IF EXISTS gst_thibaudon_valentin.temp_buffer_global;
CREATE TABLE gst_thibaudon_valentin.temp_buffer_global AS 
SELECT ST_Buffer(ST_Buffer(geom, 50), -30) as geom  -- Double buffer : +50m puis -30m
FROM gst_thibaudon_valentin.masque_total;

-- 2. On indexe cette géométrie temporaire
--  L'index spatial (GIST) accélère considérablement les opérations d'intersection qui suivent
CREATE INDEX idx_temp_buffer_geom ON gst_thibaudon_valentin.temp_buffer_global USING GIST(geom);

-- 3. On fait l'intersection par commune avec éclatement en polygones simples
-- DÉCOUPAGE COMMUNAL : Permet de produire des statistiques et cartographies par commune
-- POLYGONES SIMPLES : Chaque fragment urbain (bourg, hameau, zone d'activité) devient une ligne distincte
--  Avantages : facilite l'analyse fragment par fragment (calcul de surface, de compacité)
--  Inconvénient : plusieurs lignes par commune si tache urbaine discontinue
DROP TABLE IF EXISTS gst_thibaudon_valentin.tache_urbaine;
CREATE TABLE gst_thibaudon_valentin.tache_urbaine AS
SELECT 
    ROW_NUMBER() OVER () AS idtache,  -- Identifiant séquentiel unique pour chaque fragment de tache urbaine
    c.codgeo,   -- Code INSEE de la commune (identifiant unique)
    c.libgeo AS commune,   -- Nom de la commune
    -- ST_Dump éclate les MultiPolygons en Polygons simples
    --  Chaque fragment de tache urbaine devient une entité géographique indépendante
    (ST_Dump(ST_Intersection(b.geom, c.geom))).geom::geometry(Polygon, 2154) AS geom
FROM gst_thibaudon_valentin.temp_buffer_global b
JOIN gst_thibaudon_valentin.communes_epci_capi AS c ON ST_Intersects(b.geom, c.geom);
-- NOTE : Pas de GROUP BY car ST_Dump produit déjà plusieurs lignes par commune si fragmentation

--------------------------------------------------------------------------------
-- ETAPE 7 : couche des gisements
----------------------------------------------------------------------------------
-- OBJECTIF : Produire la couche finale `gst_bati_nonbati` avec les 4 champs attendus :
--            idgst (identifiant), nature ('bati' | 'non bati'), surface (m²), geom (Polygon,2154)
-- LOGIQUE MÉTIER :
--  1) NON BÂTI : reprend directement les morceaux de parcelles hors masques
--     calculés en ETAPE 5 (table `gnb_brut`).
--  2) BÂTI : correspond au reste des parcelles candidates une fois retranché le non bâti.
-- CHOIX TECHNIQUES :
--  - On utilise ST_Dump pour éclater les multipolygones en polygones simples.
--  - On force le SRID 2154 sur les géométries et sur le POLYGON EMPTY via
--    ST_GeomFromText('POLYGON EMPTY', 2154) afin d'éviter les erreurs de SRID mixtes.
--  - L'identifiant `idgst` est généré par ROW_NUMBER() et reste unique via un décalage
--    entre les blocs NON BÂTI et BÂTI.
DROP TABLE IF EXISTS gst_thibaudon_valentin.gst_bati_nonbati;
CREATE TABLE gst_thibaudon_valentin.gst_bati_nonbati AS

-- Zones NON BÂTIES (du gisement brut)
--  Correspondent aux espaces libres identifiés après soustraction de tous les masques
--  Représentent le potentiel foncier mobilisable pour de nouvelles constructions
SELECT 
    ROW_NUMBER() OVER (ORDER BY p.gid) AS idgst, -- Identifiant séquentiel unique pour chaque fragment
    'non bati' AS nature,                        -- Qualification de la nature du gisement
    p.area_m2 AS surface_m2,                        -- Surface en m² calculée en ETAPE 5
                                                 --  Permet le tri par taille et le calcul de surfaces cumulées
    p.geom                                       -- Géométrie (Polygon, 2154) du fragment de gisement
FROM gst_thibaudon_valentin.gnb_brut p

UNION ALL

-- Zones BÂTIES (parcelles MOINS le non-bâti)
--  Correspondent aux espaces des parcelles candidats qui sont DÉJÀ occupés (bâti, infrastructures, équipements)
--  Représentent la consommation foncière existante, en complément du gisement disponible
--  Permettent de calculer le ratio gisement / surface déjà consommée par zone
SELECT 
    ROW_NUMBER() OVER (ORDER BY p.gid) + (SELECT COUNT(*) FROM gst_thibaudon_valentin.gnb_brut) AS idgst, 
    -- Décalage pour garantir l'unicité des identifiants entre les deux blocs (non bâti + bâti)
    --  Les ID du bâti commencent où s'arrêtent ceux du non bâti
    'bati' AS nature,  -- Qualification de la nature : partie construite/occupée de la parcelle
    ST_Area(
        (ST_Dump(
            ST_Difference(
                p.geom, 
                COALESCE(g.geom_union, ST_GeomFromText('POLYGON EMPTY', 2154)) -- SRID explicite
            )
        )).geom
    ) AS surface_m2,                                                                            -- Surface en m² de la partie bâtie
    (
        ST_Dump(
            ST_Difference(
                p.geom, 
                COALESCE(g.geom_union, ST_GeomFromText('POLYGON EMPTY', 2154)) -- SRID explicite
            )
        )
    ).geom::geometry(Polygon, 2154) AS geom                                                  -- Géométrie (Polygon, 2154)
FROM gst_thibaudon_valentin.parcelles_candidates p
LEFT JOIN (
    -- Union des morceaux non bâtis par parcelle (clé `gid`)
    --  Une parcelle peut avoir plusieurs fragments de gisement non bâti
    --  ST_Union les réassemble en une géométrie unique pour faciliter la soustraction
    SELECT gid, ST_Union(geom) AS geom_union
    FROM gst_thibaudon_valentin.gnb_brut
    GROUP BY gid
) g ON p.gid = g.gid
-- LEFT JOIN : conserve les parcelles sans gisement non bâti (totalement bâties)
-- On conserve uniquement les différences non vides (surface > 0)
--  Évite de créer des polygones vides ou de surface négligeable
WHERE ST_Area(
    ST_Difference(
        p.geom, 
        COALESCE(g.geom_union, ST_GeomFromText('POLYGON EMPTY', 2154)) -- SRID explicite
    )
) > 0;
