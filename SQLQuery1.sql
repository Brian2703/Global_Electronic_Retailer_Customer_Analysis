USE ElectronicRetailerDB;

SELECT * FROM CUSTOMERS;
SELECT * FROM EXCHANGE_RATES;
SELECT * FROM PRODUCTS;
SELECT * FROM SALES;
SELECT * FROM STORES;

----------------------------------- I. DATA EXPLORATION & CLEANING --------------------------------------------

DECLARE @table_name NVARCHAR(MAX);
DECLARE @column_name NVARCHAR(MAX);
DECLARE @sql NVARCHAR(MAX);
DECLARE @query NVARCHAR(MAX);

DECLARE table_cursor CURSOR FOR
SELECT TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE';

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @table_name;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = 'SELECT COUNT(*) AS NullValues, ''' 
	+ @table_name + ''' AS TableName FROM ' + @table_name + ' WHERE ';
    DECLARE column_cursor CURSOR FOR
    SELECT COLUMN_NAME
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = @table_name;

    OPEN column_cursor;
    FETCH NEXT FROM column_cursor INTO @column_name;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = @sql + @column_name + ' IS NULL OR ';
        FETCH NEXT FROM column_cursor INTO @column_name;
    END;
    CLOSE column_cursor;
    DEALLOCATE column_cursor;

    SET @sql = LEFT(@sql, LEN(@sql) - 3); -- to remove last ' OR'
    PRINT @sql;
    EXEC sp_executesql @sql; -- execute the query
    FETCH NEXT FROM table_cursor INTO @table_name;
END;
CLOSE table_cursor;
DEALLOCATE table_cursor;
-- The result is shown that most of null value is lying in Sales with 49719 rows


----------------------------- 1. NULL VALUE IN SALES TABLE -------------------------------------------------
SELECT * FROM Sales
WHERE Order_Number IS NULL
   OR Line_Item IS NULL OR Order_Date IS NULL
   OR Delivery_Date IS NULL OR CustomerKey IS NULL
   OR StoreKey IS NULL OR ProductKey IS NULL
   OR Quantity IS NULL OR Currency_Code IS NULL;

SELECT COUNT(*) FROM Sales WHERE Delivery_Date IS NULL;

-- The null value of Delivery_date is 49719 rows, the reason is about online order
-- and in-store purchase, to prove that assumption, we check if any row appear with
-- storekey = 0

SELECT * FROM Sales WHERE Delivery_Date IS NULL AND StoreKey =0;
-- The result is none of them


--------------------------------- 2. CHECK DATA INTEGRITY --------------------------------------------------
SELECT * FROM Sales 
WHERE CustomerKey NOT IN (SELECT CustomerKey FROM Customers);

SELECT * FROM Sales 
WHERE ProductKey NOT IN (SELECT ProductKey FROM Products);

SELECT * FROM Sales 
WHERE StoreKey NOT IN (SELECT StoreKey FROM Stores);

------------------------ II. DATA ANALYSIS AND PREPARATION FOR VISUALIZATION --------------------------------

-------------------------- 1. CUSTOMER SEGMENTATION BY REVENUE OVER YEARS -----------------------------------
WITH CustomerRevenue AS (
    SELECT 
        s.CustomerKey,
        COUNT(DISTINCT s.Order_Number) AS TotalOrders, -- Count number of unique orders
        CAST(
            SUM(s.Quantity * CAST(REPLACE(p.Unit_Price_USD, '$', '') AS FLOAT))
        AS DECIMAL(10, 2)) AS Total_Sales
    FROM Sales s
    JOIN PRODUCTS p ON p.ProductKey = s.ProductKey
    GROUP BY s.CustomerKey
),

-- Percentile Segmentation
RankedCustomers AS (
    SELECT 
        CustomerKey,
        TotalOrders, -- Include order count
        Total_Sales,
        NTILE(10) OVER (ORDER BY Total_Sales DESC) AS Decile
    FROM CustomerRevenue
)

-- Final Output
SELECT 
    CustomerKey,
    TotalOrders,  -- Number of orders placed by each customer
    Total_Sales AS Final_Total_Sale,
    CASE 
        WHEN Decile = 1 THEN 'Top 10% (High Value)'
        WHEN Decile BETWEEN 2 AND 5 THEN 'Middle 40% (Medium Value)'
        ELSE 'Bottom 50% (Low Value)'
    END AS RevenueSegment
FROM RankedCustomers
ORDER BY Final_Total_Sale DESC;



------------------------------ 2. CUSTOMER RETENTION BY BY SALES COHORT -------------------------------------
-- Identify the First Purchase Date for Each Customer
WITH FirstPurchase AS ( 
    SELECT 
        CustomerKey,
        MIN(Order_Date) AS FirstPurchaseDate
    FROM Sales
    GROUP BY CustomerKey
),
-- Create the Cohorts by First Purchase Month
Cohorts AS ( 
    SELECT 
        CustomerKey,
        FORMAT(FirstPurchaseDate, 'yyyy-MM') AS CohortMonth -- Group by Year-Month
    FROM FirstPurchase
),
-- Combine Cohorts with Monthly Orders
MonthlyOrders AS (
    SELECT 
        C.CohortMonth,
        FORMAT(S.Order_date, 'yyyy-MM') AS OrderMonth,
        COUNT(DISTINCT S.CustomerKey) AS ActiveCustomers
    FROM Sales S
    INNER JOIN Cohorts C
        ON S.CustomerKey = C.CustomerKey
    GROUP BY C.CohortMonth, FORMAT(S.Order_date, 'yyyy-MM')
),
-- Calculate Retention Rates
Retention AS (
    SELECT 
        CohortMonth,
        OrderMonth,
        ActiveCustomers,
        -- Get the initial cohort size
        MAX(ActiveCustomers) OVER (PARTITION BY CohortMonth) AS CohortSize,
        -- Calculate retention rate as a percentage
        (ActiveCustomers * 100.0 / MAX(ActiveCustomers) OVER (PARTITION BY CohortMonth)) AS RetentionRate
    FROM MonthlyOrders
)

-- Final Output: Retention Table
SELECT 
    CohortMonth,
    OrderMonth,
    ActiveCustomers,
    CohortSize,
    ROUND(RetentionRate,2) AS RetentionRate
FROM Retention
ORDER BY CohortMonth, OrderMonth;








WITH FirstPurchase AS ( 
    SELECT 
        CustomerKey,
        MIN(Order_Date) AS FirstPurchaseDate
    FROM Sales
    GROUP BY CustomerKey
),
Cohorts AS ( 
    SELECT 
        CustomerKey,
        FORMAT(FirstPurchaseDate, 'yyyy-MM') AS CohortMonth
    FROM FirstPurchase
),
ReturningCustomers AS (
    -- Identify customers who purchased after their first purchase date
    SELECT 
        S.CustomerKey,
        FORMAT(S.Order_Date, 'yyyy-MM') AS OrderMonth
    FROM Sales S
    INNER JOIN FirstPurchase FP 
        ON S.CustomerKey = FP.CustomerKey 
        AND S.Order_Date > FP.FirstPurchaseDate  -- Exclude first-time purchases
),
MonthlyReturningCustomers AS (
    -- Count only returning customers in each month
    SELECT 
        OrderMonth,
        COUNT(DISTINCT CustomerKey) AS ReturningCustomers
    FROM ReturningCustomers
    GROUP BY OrderMonth
)
SELECT * FROM MonthlyReturningCustomers
ORDER BY OrderMonth;


-------------------------------- 4. PAIRS OF SUBCAT GO TOGETHER -----------------------------------------------
WITH ProductPairs AS (
    SELECT 
        S1.Order_Number, 
        P1.Subcategory AS Subcategory_A, 
        P2.Subcategory AS Subcategory_B
    FROM Sales S1
    JOIN Sales S2 ON S1.Order_Number = S2.Order_Number  -- Products in the same order
    JOIN Products P1 ON S1.ProductKey = P1.ProductKey
    JOIN Products P2 ON S2.ProductKey = P2.ProductKey
    WHERE S1.ProductKey < S2.ProductKey -- Avoid duplicate pairs (A,B) and (B,A)
)

SELECT 
    Subcategory_A, 
    Subcategory_B, 
    COUNT(*) AS PairCount
FROM ProductPairs
GROUP BY Subcategory_A, Subcategory_B HAVING Subcategory_A!=Subcategory_B
ORDER BY PairCount DESC OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY;
