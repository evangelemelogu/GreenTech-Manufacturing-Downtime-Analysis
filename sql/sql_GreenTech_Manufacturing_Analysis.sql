/*
    GreenTech Manufacturing
    Production Downtime Analysis

    Platform: Microsoft SQL Server (T-SQL)
    Author: Evangelista Emelogu

    Expected source tables in dbo:
      - products
      - line_productivity_batches
      - line_downtime
      - downtime_factors

    This consolidated script replaces the two working SQL files used during
    development. It retains their useful validation and analysis queries while
    correcting missing dependencies, ambiguous labels, and sorting errors.
*/

USE [GreenTech_Manufacturing];
GO

SET NOCOUNT ON;
GO

/* 1. DATA UNDERSTANDING */

SELECT TOP (10) * FROM dbo.products;
SELECT TOP (10) * FROM dbo.line_productivity_batches;
SELECT TOP (10) * FROM dbo.line_downtime;
SELECT TOP (10) * FROM dbo.downtime_factors;

SELECT 'products' AS Table_Name, COUNT(*) AS Row_Count FROM dbo.products
UNION ALL
SELECT 'line_productivity_batches', COUNT(*) FROM dbo.line_productivity_batches
UNION ALL
SELECT 'line_downtime', COUNT(*) FROM dbo.line_downtime
UNION ALL
SELECT 'downtime_factors', COUNT(*) FROM dbo.downtime_factors;


/*  2. DATA QUALITY ASSESSMENT */

-- Required-key null checks
SELECT * FROM dbo.products WHERE Product_ID IS NULL;
SELECT * FROM dbo.line_productivity_batches WHERE Batch_ID IS NULL;
SELECT * FROM dbo.line_downtime WHERE Batch_ID IS NULL;
SELECT * FROM dbo.downtime_factors WHERE Factor_ID IS NULL;

-- Duplicate-key checks
SELECT Product_ID, COUNT(*) AS Record_Count
FROM dbo.products
GROUP BY Product_ID
HAVING COUNT(*) > 1;

SELECT Batch_ID, COUNT(*) AS Record_Count
FROM dbo.line_productivity_batches
GROUP BY Batch_ID
HAVING COUNT(*) > 1;

SELECT Batch_ID, COUNT(*) AS Record_Count
FROM dbo.line_downtime
GROUP BY Batch_ID
HAVING COUNT(*) > 1;

SELECT Factor_ID, COUNT(*) AS Record_Count
FROM dbo.downtime_factors
GROUP BY Factor_ID
HAVING COUNT(*) > 1;

-- Product references in the batch table that do not exist in products
SELECT DISTINCT Product_ID
FROM dbo.line_productivity_batches
EXCEPT
SELECT Product_ID
FROM dbo.products;

-- Batch references in downtime that do not exist in the batch table
SELECT DISTINCT Batch_ID
FROM dbo.line_downtime
EXCEPT
SELECT Batch_ID
FROM dbo.line_productivity_batches;

-- Dates embedded in Start_Time that disagree with the Date field
SELECT
    Batch_ID,
    [Date] AS Recorded_Date,
    CAST(Start_Time AS date) AS Start_Date
FROM dbo.line_productivity_batches
WHERE [Date] <> CAST(Start_Time AS date);

-- Batches where every factor field is null
SELECT COUNT(*) AS Batches_With_All_Factors_Null
FROM dbo.line_downtime
WHERE COALESCE(
    Factor_1, Factor_2, Factor_3, Factor_4, Factor_5,
    Factor_6, Factor_7, Factor_8, Factor_9, Factor_10,
    Factor_11, Factor_12, Factor_13
) IS NULL;


/*  3. REUSABLE ANALYTICAL VIEWS */

-- One row per positive downtime event. Zero-minute entries are excluded.
GO
CREATE OR ALTER VIEW dbo.vw_GreenTech_DowntimeEvents
AS
SELECT
    Batch_ID,
    CAST(REPLACE(Factor_Column, 'Factor_', '') AS int) AS Factor_ID,
    Downtime_Minutes
FROM dbo.line_downtime
UNPIVOT
(
    Downtime_Minutes FOR Factor_Column IN
    (
        Factor_1, Factor_2, Factor_3, Factor_4, Factor_5,
        Factor_6, Factor_7, Factor_8, Factor_9, Factor_10,
        Factor_11, Factor_12, Factor_13
    )
) AS unpvt
WHERE Downtime_Minutes > 0;
GO

-- Master analysis view. The left join retains downtime-free batches.
CREATE OR ALTER VIEW dbo.vw_GreenTech_MasterAnalysis
AS
SELECT
    b.[Date] AS Production_Date,
    b.Product_ID,
    p.Product_Name,
    p.Category,
    b.Batch_ID,
    b.Operator,
    b.Start_Time,
    b.End_Time,
    b.Planned_Min_Batch_Hours,
    DATEDIFF(MINUTE, b.Start_Time, b.End_Time) AS Actual_Duration_Minutes,
    CAST(b.Planned_Min_Batch_Hours * 60.0 AS decimal(12,2)) AS Planned_Duration_Minutes,
    e.Factor_ID,
    f.Factor_Name,
    f.Description AS Factor_Description,
    f.Operator_Error,
    COALESCE(e.Downtime_Minutes, 0) AS Downtime_Minutes,
    CASE WHEN e.Batch_ID IS NULL THEN 0 ELSE 1 END AS Has_Downtime
FROM dbo.line_productivity_batches AS b
INNER JOIN dbo.products AS p
    ON b.Product_ID = p.Product_ID
LEFT JOIN dbo.vw_GreenTech_DowntimeEvents AS e
    ON b.Batch_ID = e.Batch_ID
LEFT JOIN dbo.downtime_factors AS f
    ON e.Factor_ID = f.Factor_ID;
GO


/* 4. TRANSFORMATION VALIDATION */

-- Expected source results for the supplied portfolio data:
-- 645 batches, 875 positive downtime events, 363 affected batches,
-- and 31,310 downtime minutes.
SELECT COUNT(*) AS Positive_Downtime_Events
FROM dbo.vw_GreenTech_DowntimeEvents;

SELECT
    COUNT(DISTINCT Batch_ID) AS Total_Batches,
    COUNT(DISTINCT CASE WHEN Has_Downtime = 1 THEN Batch_ID END) AS Affected_Batches,
    COUNT(DISTINCT CASE WHEN Has_Downtime = 0 THEN Batch_ID END) AS Downtime_Free_Batches,
    SUM(Downtime_Minutes) AS Total_Downtime_Minutes
FROM dbo.vw_GreenTech_MasterAnalysis;

-- Reconcile recorded downtime with the difference between actual and planned time.
WITH batch_duration AS
(
    SELECT DISTINCT
        Batch_ID,
        Actual_Duration_Minutes,
        Planned_Duration_Minutes
    FROM dbo.vw_GreenTech_MasterAnalysis
)
SELECT
    SUM(Actual_Duration_Minutes - Planned_Duration_Minutes) AS Schedule_Gap_Minutes,
    (SELECT SUM(Downtime_Minutes) FROM dbo.vw_GreenTech_DowntimeEvents)
        AS Logged_Downtime_Minutes
FROM batch_duration;


/* 5. EXPLORATORY ANALYSIS */

-- Downtime by factor
SELECT
    Factor_Name,
    COUNT(*) AS Downtime_Events,
    SUM(Downtime_Minutes) AS Downtime_Minutes,
    ROUND(SUM(Downtime_Minutes) / 60.0, 2) AS Downtime_Hours
FROM dbo.vw_GreenTech_MasterAnalysis
WHERE Has_Downtime = 1
GROUP BY Factor_Name
ORDER BY Downtime_Minutes DESC;

-- Top five factors overall
SELECT TOP (5)
    Factor_Name,
    COUNT(*) AS Downtime_Events,
    SUM(Downtime_Minutes) AS Downtime_Minutes
FROM dbo.vw_GreenTech_MasterAnalysis
WHERE Has_Downtime = 1
GROUP BY Factor_Name
ORDER BY Downtime_Minutes DESC;

-- Downtime by product, adjusted for batch volume
WITH batch_loss AS
(
    SELECT
        b.Batch_ID,
        b.Product_ID,
        p.Product_Name,
        SUM(COALESCE(e.Downtime_Minutes, 0)) AS Downtime_Minutes
    FROM dbo.line_productivity_batches AS b
    INNER JOIN dbo.products AS p
        ON b.Product_ID = p.Product_ID
    LEFT JOIN dbo.vw_GreenTech_DowntimeEvents AS e
        ON b.Batch_ID = e.Batch_ID
    GROUP BY b.Batch_ID, b.Product_ID, p.Product_Name
)
SELECT
    Product_ID,
    Product_Name,
    COUNT(*) AS Total_Batches,
    COUNT(CASE WHEN Downtime_Minutes > 0 THEN 1 END) AS Affected_Batches,
    SUM(Downtime_Minutes) AS Downtime_Minutes,
    ROUND(AVG(Downtime_Minutes * 1.0), 2) AS Downtime_Minutes_Per_Batch,
    ROUND(
        COUNT(CASE WHEN Downtime_Minutes > 0 THEN 1 END) * 100.0 / COUNT(*),
        2
    ) AS Affected_Batch_Rate_Pct
FROM batch_loss
GROUP BY Product_ID, Product_Name
ORDER BY Downtime_Minutes DESC;

-- Top five downtime factors within each product
WITH factor_totals AS
(
    SELECT
        Product_ID,
        Product_Name,
        Factor_Name,
        SUM(Downtime_Minutes) AS Downtime_Minutes
    FROM dbo.vw_GreenTech_MasterAnalysis
    WHERE Has_Downtime = 1
    GROUP BY Product_ID, Product_Name, Factor_Name
),
ranked_factors AS
(
    SELECT
        *,
        ROW_NUMBER() OVER
        (
            PARTITION BY Product_ID
            ORDER BY Downtime_Minutes DESC
        ) AS Factor_Rank
    FROM factor_totals
)
SELECT
    Product_ID,
    Product_Name,
    Factor_Rank,
    Factor_Name,
    Downtime_Minutes
FROM ranked_factors
WHERE Factor_Rank <= 5
ORDER BY Product_ID, Factor_Rank;

-- Operator performance with workload context
WITH batch_loss AS
(
    SELECT
        b.Batch_ID,
        b.Operator,
        b.Product_ID,
        SUM(COALESCE(e.Downtime_Minutes, 0)) AS Downtime_Minutes
    FROM dbo.line_productivity_batches AS b
    LEFT JOIN dbo.vw_GreenTech_DowntimeEvents AS e
        ON b.Batch_ID = e.Batch_ID
    GROUP BY b.Batch_ID, b.Operator, b.Product_ID
)
SELECT
    Operator,
    COUNT(*) AS Total_Batches,
    COUNT(DISTINCT Product_ID) AS Products_Handled,
    COUNT(CASE WHEN Downtime_Minutes > 0 THEN 1 END) AS Affected_Batches,
    SUM(Downtime_Minutes) AS Downtime_Minutes,
    ROUND(AVG(Downtime_Minutes * 1.0), 2) AS Downtime_Minutes_Per_Batch,
    ROUND(
        COUNT(CASE WHEN Downtime_Minutes > 0 THEN 1 END) * 100.0 / COUNT(*),
        2
    ) AS Affected_Batch_Rate_Pct
FROM batch_loss
GROUP BY Operator
ORDER BY Downtime_Minutes DESC;

-- Operator vs non-operator factor classification
SELECT
    CASE
        WHEN Operator_Error = 1 THEN 'Operator-labelled factor'
        WHEN Operator_Error = 0 THEN 'Non-operator factor'
        ELSE 'Unclassified'
    END AS Factor_Classification,
    COUNT(*) AS Downtime_Events,
    SUM(Downtime_Minutes) AS Downtime_Minutes,
    ROUND(
        SUM(Downtime_Minutes) * 100.0 /
        SUM(SUM(Downtime_Minutes)) OVER (),
        2
    ) AS Share_Of_Downtime_Pct
FROM dbo.vw_GreenTech_MasterAnalysis
WHERE Has_Downtime = 1
GROUP BY
    CASE
        WHEN Operator_Error = 1 THEN 'Operator-labelled factor'
        WHEN Operator_Error = 0 THEN 'Non-operator factor'
        ELSE 'Unclassified'
    END
ORDER BY Downtime_Minutes DESC;


/* 6. EXECUTIVE KPI SUMMARY */

WITH batch_loss AS
(
    SELECT
        b.Batch_ID,
        SUM(COALESCE(e.Downtime_Minutes, 0)) AS Downtime_Minutes
    FROM dbo.line_productivity_batches AS b
    LEFT JOIN dbo.vw_GreenTech_DowntimeEvents AS e
        ON b.Batch_ID = e.Batch_ID
    GROUP BY b.Batch_ID
),
factor_classification AS
(
    SELECT
        SUM(CASE WHEN f.Operator_Error = 1 THEN e.Downtime_Minutes ELSE 0 END)
            AS Operator_Error_Minutes,
        SUM(CASE WHEN f.Operator_Error = 0 THEN e.Downtime_Minutes ELSE 0 END)
            AS Non_Operator_Error_Minutes
    FROM dbo.vw_GreenTech_DowntimeEvents AS e
    INNER JOIN dbo.downtime_factors AS f
        ON e.Factor_ID = f.Factor_ID
)
SELECT
    COUNT(*) AS Total_Production_Batches,
    COUNT(CASE WHEN Downtime_Minutes > 0 THEN 1 END) AS Batches_With_Downtime,
    COUNT(CASE WHEN Downtime_Minutes = 0 THEN 1 END) AS Downtime_Free_Batches,
    SUM(Downtime_Minutes) AS Total_Downtime_Minutes,
    ROUND(SUM(Downtime_Minutes) / 60.0, 2) AS Total_Downtime_Hours,
    ROUND(AVG(Downtime_Minutes * 1.0), 2) AS Avg_Downtime_Minutes_All_Batches,
    ROUND(
        AVG(CASE WHEN Downtime_Minutes > 0 THEN Downtime_Minutes * 1.0 END),
        2
    ) AS Avg_Downtime_Minutes_Affected_Batches,
    ROUND(
        COUNT(CASE WHEN Downtime_Minutes > 0 THEN 1 END) * 100.0 / COUNT(*),
        2
    ) AS Downtime_Incidence_Rate_Pct,
    ROUND(
        COUNT(CASE WHEN Downtime_Minutes = 0 THEN 1 END) * 100.0 / COUNT(*),
        2
    ) AS Downtime_Free_Rate_Pct,
    ROUND(
        fc.Operator_Error_Minutes * 100.0 / NULLIF(SUM(bl.Downtime_Minutes), 0),
        2
    ) AS Operator_Error_Share_Pct,
    ROUND(
        fc.Non_Operator_Error_Minutes * 100.0 / NULLIF(SUM(bl.Downtime_Minutes), 0),
        2
    ) AS Non_Operator_Error_Share_Pct
FROM batch_loss AS bl
CROSS JOIN factor_classification AS fc
GROUP BY fc.Operator_Error_Minutes, fc.Non_Operator_Error_Minutes;

